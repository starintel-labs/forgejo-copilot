:- module(service,
          [ init/1,
            poll_once/1,
            process_event/5,
            resume_paused/1,
            api_call/3,
            default_options/1
          ]).

/** <module> Service daemon

Long-running polling service. There is no inbound network surface: the
service polls the configured Forgejo API with an `updated_since` cursor and
seen-event idempotency in the durable journal.

Pipeline per event:

    poll -> classify (forgejo_event) -> admission gate (spec) ->
    lease claim (with run identity) -> rlm_graph run (persistent
    checkpoints) -> effect record + lease release -> visible failure
    comment when the model chain is exhausted

Refusals are distinguishable (admission:admit_reason/7): bot, disabled,
not_triggered, already_done, lease_held. Final refusals mark the event
seen; lease_held leaves it unseen so the run can be resumed (or retried
after a crash, from the lease's recorded run identity).

Options (list of Name(Value)):

    state_dir(Dir)     durable state root (journal + graph checkpoints)
    repos(Repos)       list of owner/name atoms to watch
    poll_seconds(N)    interval for run_forever (never used in tests)
    delegate(Module)   graph node delegate (copilot_delegate)
    api(Pred3)         trusted Forgejo call hook (default service:api_call)

All credentials come from the environment and are never logged.
*/

:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(fcopilot(copilot_config)).
:- use_module(fcopilot(admission)).
:- use_module(fcopilot(copilot_graph)).
:- use_module(fcopilot(copilot_delegate), []).
:- use_module(fcopilot(forgejo_event)).
:- use_module(fcopilot(forgejo), []).
:- use_module(fcopilot(journal)).
:- use_module(library(rlm)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(base64)).

default_options([state_dir('state/run'),
                 repos([]),
                 poll_seconds(30),
                 delegate(copilot_delegate)]).

%% init(+Options) is det.
init(Options) :-
    option(state_dir(Dir), Options),
    make_directory_path(Dir),
    format(atom(JournalPath), '~w/journal.pl', [Dir]),
    (   journal:attached(JournalPath)
    ->  true
    ;   catch(journal:close, _, true),
        journal:open(JournalPath)
    ).

%% poll_once(+Options) is det.
poll_once(Options) :-
    init(Options),
    option(repos(Repos), Options),
    forall(member(Repo, Repos), poll_repo(Repo, Options)).

poll_repo(Repo, Options) :-
    (   journal:cursor_get(Repo, Since)
    ->  true
    ;   Since = epoch0
    ),
    list_events(Repo, Since, Events),
    forall(member(Event, Events),
           handle_polled(Repo, Event, Options)),
    (   Events == []
    ->  true
    ;   maplist(poll_time, Events, Times),
        max_list(Times, Last),
        journal:cursor_advance(Repo, Last)
    ).

%% handle_polled(+Repo, +Polled, +Options) is det.
handle_polled(Repo, Polled, Options) :-
    event_key(Repo, Polled, EventKey),
    (   journal:seen(EventKey)
    ->  true
    ;   classify_polled(Polled, SpecEvent),
        process_event(Repo, Polled, SpecEvent, EventKey, Options)
    ).

event_key(Repo, Polled, EventKey) :-
    format(atom(EventKey), '~w:~w:~w:~w', [Repo, Polled.pr, Polled.sha,
                                           Polled.event_id]).

classify_polled(Polled, Event) :-
    (   Polled.kind_hint == pr_opened
    ->  Event = event{actor:Polled.login,
                      actor_kind:actor_kind_of(Polled.bot),
                      kind:pr_opened}
    ;   forgejo_event:to_spec_event(Polled.login, Polled.bot, Polled.body,
                                    Event0)
    ->  Event = Event0
    ;   Event = event{actor:Polled.login,
                      actor_kind:actor_kind_of(Polled.bot),
                      kind:unknown}
    ).

actor_kind_of(true) :- !, bot.
actor_kind_of(false) :- human.

%% process_event(+Repo, +Polled, +Event, +EventKey, +Options) is det.
process_event(Repo, Polled, Event, EventKey, Options) :-
    init(Options),
    PR = Polled.pr,
    Sha = Polled.sha,
    base_config(Repo, PR, Options, ConfigFileSpec),
    copilot_config:parse(ConfigFileSpec, Config),
    journal:facts(Facts),
    (   Event.kind == unknown
    ->  journal:mark_seen(EventKey)                 % not a trigger; silent
    ;   admission:admit_reason(Repo, PR, Sha, Event, Config, Facts, Decision)
    ->  handle_decision(Repo, Polled, Event, Config, Decision, EventKey,
                        Options)
    ;   journal:mark_seen(EventKey)
    ).

handle_decision(_Repo, _Polled, _Event, _Config, ok(Grant), EventKey,
                Options) :-
    !,
    journal:lease_acquire(Grant.repo, Grant.pr, Grant.sha, _Token),
    run_task(Grant, Options),
    journal:mark_seen(EventKey).
handle_decision(Repo, Polled, _Event, _Config,
                refused(already_done), EventKey, _Options) :-
    !,
    journal:mark_seen(EventKey),
    print_message(informational, service(already_done(Repo, Polled.pr))).
handle_decision(_Repo, _Polled, _Event, _Config, refused(lease_held),
                _EventKey, Options) :-
    !,
    % Leave unseen; a crashed run is resumed via the lease's run identity.
    resume_paused(Options).
handle_decision(_Repo, _Polled, Event, _Config, refused(Reason), EventKey,
                _Options) :-
    journal:mark_seen(EventKey),
    print_message(informational, service(refused(Reason, Event.kind))).

%% resume_paused(+Options) is det.
% Fresh-process resumption: for every held lease, re-run its graph run.
% A terminal outcome releases the lease inside finalize_run/3; a run that
% pauses again keeps its lease because it is still resumable. A held lease
% with no durable checkpoint (crashed before the first checkpoint) or a
% refused resume (e.g. completed run) is released so the next poll can
% re-admit the event.
resume_paused(Options) :-
    init(Options),
    forall(journal:lease_runs(run(Repo, PR, Sha)),
           resume_lease_run(Repo, PR, Sha, Options)).

resume_lease_run(Repo, PR, Sha, Options) :-
    run_id(Repo, PR, Sha, RunId),
    (   resume_one(RunId, Options)
    ->  true
    ;   (   journal:lease_held(Repo, PR, Tok)
        ->  journal:lease_release(Repo, PR, Tok)
        ;   true
        )
    ).

resume_one(RunId, Options) :-
    option(state_dir(Dir), Options),
    format(atom(GraphDb), '~w/graph-checkpoints.pl', [Dir]),
    option(delegate(Delegate), Options),
    api_option(Options, Api),
    copilot_graph:compile(Compiled),
    rlm:graph_backend_open(persist(GraphDb), Backend),
    setup_call_cleanup(
        true,
        (   rlm:graph_checkpoint(Backend, RunId, Snapshot)
        ->  get_dict(state, Snapshot, SnapshotState),
            get_dict(data, SnapshotState, Data0),
            get_dict(grant, Data0, Grant),
            % graph_resume reloads its state from the durable checkpoint,
            % never from a locally patched copy, so the fresh-process
            % delegate/api closures must be delivered through the resume
            % patch; patching only a local State would be silently lost
            % and the run would re-pause on the stale delegate.
            Data = Data0.put(delegate, Delegate).put(api, Api),
            catch(rlm:graph_resume(Compiled, Backend, RunId,
                                   resume(resumed, patch{data: Data}),
                                   [], Outcome0),
                  GraphError,
                  Outcome0 = error(graph_error{exception:GraphError})),
            finalize_run(Grant, Outcome0, Options)
        ;   true
        ),
        rlm:graph_backend_close(Backend)).

%% base_config(+Repo, +PR, +Options, -FileSpec) is det.
% The .copilot file is read from the PR BASE branch HEAD only. A .copilot
% inside the PR branch never self-enables (spec). For an issue (no PR),
% the repo's default branch head is used instead.
base_config(Repo, PR, Options, FileSpec) :-
    (   base_branch(Repo, PR, Options, BaseBranch)
    ->  true
    ;   default_branch(BaseBranch)
    ),
    copilot_file_content(Repo, BaseBranch, Options, Text),
    !,
    FileSpec = Text.
base_config(_Repo, _PR, _Options, none).

default_branch(Branch) :-
    (   getenv('COPILOT_DEFAULT_BRANCH', B), B \== ''
    ->  Branch = B
    ;   Branch = 'main'
    ).

%% copilot_file_content(+Repo, +Branch, +Options, -Text) is semidet.
% Host-side read of .copilot from the given branch HEAD (never a model
% tool), routed through the trusted api hook so tests can substitute it.
copilot_file_content(Repo, Branch, Options, Text) :-
    split_repo(Repo, Owner, Name),
    api_option(Options, Api),
    catch(call(Api, get_file_content,
               _{owner:Owner, repo:Name, branch:Branch, path:'.copilot'},
               _{text:Text0}),
          _, fail),
    !,
    Text = Text0.

base_branch(Repo, PR, Options, BaseBranch) :-
    api_option(Options, Api),
    split_repo(Repo, Owner, Name),
    call(Api, get_pr, _{owner:Owner, repo:Name, index:PR}, Pull),
    get_dict(base, Pull, BaseInfo),
    get_dict(ref, BaseInfo, BaseBranch).

api_option(Options, Api) :-
    option(api(Api), Options),
    !.
api_option(_Options, service:api_call).

%% run_task(+Grant, +Options) is det.
run_task(Grant, Options) :-
    option(state_dir(Dir), Options),
    format(atom(GraphDb), '~w/graph-checkpoints.pl', [Dir]),
    option(delegate(Delegate), Options),
    api_option(Options, Api),
    run_id(Grant.repo, Grant.pr, Grant.sha, RunId),
    Data0 = run_data{grant:Grant, api:Api, delegate:Delegate},
    (   base_branch(Grant.repo, Grant.pr, Options, BaseBranch)
    ->  Data = Data0.put(base_branch, BaseBranch)
    ;   Data = Data0
    ),
    copilot_graph:compile(Compiled),
    setup_call_cleanup(
        rlm:graph_backend_open(persist(GraphDb), Backend),
        (   catch(rlm:graph_run(Compiled,
                                state{data:Data},
                                [backend(Backend), run_id(RunId)],
                                Outcome0),
                  GraphError,
                  Outcome0 = error(graph_error{exception:GraphError})),
            finalize_run(Grant, Outcome0, Options)
        ),
        rlm:graph_backend_close(Backend)).

run_id(Repo, PR, Sha, RunId) :-
    format(atom(RunId), 'run:~w:~w:~w', [Repo, PR, Sha]).

%% finalize_run(+Grant, +Outcome, +Options) is det.
finalize_run(Grant, ok(Completed), _Options) :-
    get_dict(status, Completed.state, done),
    !,
    make_uuid_id(EffectId),
    journal:record_effect(Grant.repo, Grant.pr, Grant.sha, comment, EffectId),
    release_lease(Grant).
finalize_run(Grant, ok(Completed), Options) :-
    get_dict(status, Completed.state, failed),
    !,
    % The model chain is exhausted: the terminal step is a visible failure
    % comment on the issue — never a silent failure.
    post_failure_comment(Grant, Completed.state, Options),
    release_lease(Grant).
finalize_run(_Grant, ok(_Paused), _Options) :-
    true.                                      % paused: resumable checkpoint
finalize_run(_Grant, error(E), _Options) :-
    print_message(error, service(graph_run_failed(E))),
    fail.

post_failure_comment(Grant, State, Options) :-
    get_dict(error, State, Err),
    format(atom(Body),
           'copilot: could not complete task for ~w — model chain exhausted (~w). No action was taken.',
           [Grant.sha, Err]),
    catch((   api_option(Options, Api),
              split_repo(Grant.repo, Owner, Name),
              call(Api, post_issue_comment,
                   _{owner:Owner, repo:Name, index:Grant.pr, body:Body},
                   _Value)
          ),
          _,
          print_message(error, service(failure_comment_undeliverable(Grant)))).

release_lease(Grant) :-
    (   journal:lease_held(Grant.repo, Grant.pr, Tok)
    ->  journal:lease_release(Grant.repo, Grant.pr, Tok)
    ;   true
    ).

make_uuid_id(Id) :-
    get_time(T),
    format(atom(Id), 'fx-~w', [T]).

%% list_events(+Repo, +Since, -Polled) is det.
% Host-side Forgejo polling (not a model tool): issues updated since the
% cursor become candidate events. For issues the head-sha slot carries the
% issue's updated_at so each new activity re-admits (the issue analog of a
% force push).
list_events(Repo, _Since, []) :-
    \+ forgejo_configured,
    !,
    print_message(informational, service(forgejo_not_configured(Repo))).
list_events(Repo, _Since, Events) :-
    forgejo_configured,
    !,
    split_repo(Repo, Owner, Name),
    catch(forgejo_tools:handler(list_issues_updated_since,
                                _{owner:Owner, repo:Name,
                                  since:'1970-01-01T00:00:00Z'},
                                _{issues:Issues}),
          _,
          Issues = []),
    maplist(issue_to_polled(Repo), Issues, Events).

forgejo_configured :-
    getenv('FORGEJO_URL', U),
    U \== ''.

issue_to_polled(Repo, Issue, polled{repo:Repo,
                                    pr:Issue.number,
                                    sha:Issue.updated_at,
                                    login:Issue.user.login,
                                    bot:bot_flag(Issue.user),
                                    body:Issue.body,
                                    kind_hint:comment,
                                    event_id:comment(Issue.updated_at,
                                                     Issue.user.login)}).

bot_flag(User) :-
    (   get_dict(bot, User, true) -> true ; false ).

%% api_call(+Tool, +Args, -Value) is det.
% Default trusted Forgejo hook. This is trusted host configuration, not
% model tool use: capabilities do not apply to host-side polling.
api_call(get_file_content,
         _{owner:Owner, repo:Repo, branch:Branch, path:Path},
         _{text:Text}) :-
    !,
    forgejo_tools:get_file_content(Owner, Repo, Branch, Path, Text).
api_call(Tool, Args, Value) :-
    forgejo_tools:handler(Tool, Args, Value).

split_repo(Repo, Owner, Name) :-
    atom_codes(Repo, Codes),
    append(OwnerCodes, [0'/ | NameCodes], Codes),
    !,
    atom_codes(Owner, OwnerCodes),
    atom_codes(Name, NameCodes).

poll_time(Polled, T) :-
    (   get_dict(updated, Polled, T0), number(T0)
    ->  T = T0
    ;   T = 0
    ).
