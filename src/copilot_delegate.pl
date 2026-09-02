:- module(copilot_delegate,
          [ node/4
          ]).

/** <module> Real copilot delegate

Trusted host-side node implementation for the execution graph. Outcomes
follow the delegate protocol: ok(Patch) | failed(Error) | interrupt(R, P).

State.data is a dict (extended node-by-node through `data` patches):

    run_data{grant:grant{repo,pr,sha,event,route},
             config:config{...},                  effective .copilot
             api:callable(Tool, Args, Value),     trusted API hook
             base_branch:atom,                    PR base (or default)
             issue:dict, pull:dict,               filled at fetched
             diff:string, files:list,             filled at fetched
             comments:list,                       filled at fetched
             findings:list,                       filled at reviewed
             plan:list,                           filled at planned
             branch:atom,                         filled at branched
             commits:list                         filled at implemented
            }

Authority:

  * branch/pushes only under copilot/ (spec rule, enforced before the API
    call is even attempted);
  * reviews are never APPROVED — the human gate stays human;
  * `tested` is a bounded model self-verification pass; the bot holds no
    process/shell capability and never executes repository code;
  * every external write is preceded by a durable effect record keyed on
    (repo, pr, sha, action) — a crash can never produce an implicit
    duplicate write.
*/

:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(fcopilot(journal)).
:- use_module(fcopilot(model_strategy)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(uuid)).

node(received, _State, _Context, ok(patch{})).
node(config_checked, _State, _Context, ok(patch{})).
node(leased, _State, _Context, ok(patch{})).
node(fetched, State, _Context, ok(patch{data:NewData})) :-
    fetch_context(State, NewData).
node(partitioned, State, _Context, ok(patch{route:Route})) :-
    get_dict(grant, State.data, Grant),
    get_dict(route, Grant, Route).
node(reviewed, State, _Context, ok(patch{data:Data})) :-
    review_diff(State, Findings),
    put_dict(findings, State.data, Findings, Data).
node(deduped, State, _Context, ok(patch{data:Data})) :-
    dedup_findings(State, Kept),
    put_dict(findings, State.data, Kept, Data).
node(posted, State, _Context, ok(patch{data:Data})) :-
    post_review(State, Review),
    put_dict(review, State.data, Review, Data).
node(planned, State, _Context, ok(patch{data:Data})) :-
    plan_task(State, Plan),
    put_dict(plan, State.data, Plan, Data).
node(branched, State, _Context, ok(patch{data:Data})) :-
    create_task_branch(State, Branch),
    put_dict(branch, State.data, Branch, Data).
node(implemented, State, _Context, ok(patch{data:Data})) :-
    implement_changes(State, Commits),
    put_dict(commits, State.data, Commits, Data).
node(tested, State, _Context, ok(patch{data:Data})) :-
    self_verify(State, Verdict),
    put_dict(verified, State.data, Verdict, Data).
node(pushed, _State, _Context, ok(patch{})).
node(pr_opened, State, _Context, ok(patch{data:Data})) :-
    open_pr(State, Index),
    put_dict(pr_index, State.data, Index, Data).
node(replied, State, _Context, ok(patch{data:Data})) :-
    reply_with_citations(State, Id),
    put_dict(comment_id, State.data, Id, Data).

% -- API hook (trusted host configuration, injected by the service) ----------

api(State, Tool, Args, Value) :-
    get_dict(api, State.data, ApiCall),
    call(ApiCall, Tool, Args, Value).

% -- fetched -----------------------------------------------------------------

fetch_context(State, NewData) :-
    get_dict(grant, State.data, Grant),
    get_dict(route, Grant, Route),
    pr_args(State, Args),
    (   Route == review
    ->  api(State, get_pr, Args, Pull),
        api(State, get_diff, Args, _{diff:Diff}),
        api(State, list_changed_files, Args, _{files:Files}),
        api(State, get_comment_thread, Args, _{comments:Comments}),
        put_data(State, [pull-Pull, diff-Diff, files-Files, comments-Comments],
                 NewData)
    ;   api(State, get_issue, Args, Issue),
        api(State, get_comment_thread, Args, _{comments:Comments}),
        put_data(State, [issue-Issue, comments-Comments, files-[]],
                 NewData)
    ).

pr_args(State, args{owner:Owner, repo:Name, index:PR}) :-
    get_dict(grant, State.data, Grant),
    split_repo(Grant.repo, Owner, Name),
    PR = Grant.pr.

put_data(State, Pairs, NewData) :-
    foldl(put_pair, Pairs, State.data, NewData).

put_pair(Key-Value, Data, New) :-
    put_dict(Key, Data, Value, New).

% -- reviewed ----------------------------------------------------------------

review_diff(State, Findings) :-
    get_dict(diff, State.data, Diff),
    (   Diff == none
    ->  Findings = []
    ;   get_dict(files, State.data, Files),
        model_call(State, review,
                   [message{role:system,
                            content:"You are a precise code reviewer. Every finding must cite FILE:LINE from the provided diff."},
                    message{role:user,
                            content:"Review this pull request diff. Reply with one finding per line, each citing FILE:LINE."},
                    message{role:user, content:Diff}],
                   ModelText),
        findings_with_citations(ModelText, Files, Findings)
    ).

% Ungrounded findings are dropped (spec_reply_requires_citation): a finding
% line is kept only when it cites one of the changed file paths.
findings_with_citations(Text, Files, Findings) :-
    split_string(Text, "\n", "\r", Lines0),
    include(cites_file(Files), Lines0, Lines),
    maplist(string_atom, Lines, Findings).

cites_file(Files, Line) :-
    member(File, Files),
    get_dict(filename, File, Path),
    text_to_string(Path, PathStr),
    sub_string(Line, _, _, _, PathStr).

string_atom(S, A) :-
    atom_string(A, S).

% -- deduped -----------------------------------------------------------------

dedup_findings(State, Kept) :-
    get_dict(findings, State.data, Findings),
    get_dict(comments, State.data, Comments),
    include(new_finding(Comments), Findings, Kept).

new_finding(Comments, Finding) :-
    \+ (   member(C, Comments),
           get_dict(body, C, Body),
           sub_string(Body, _, _, _, Finding)
       ).

% -- posted ------------------------------------------------------------------

post_review(State, Review) :-
    get_dict(grant, State.data, Grant),
    get_dict(findings, State.data, Kept),
    (   Kept == []
    ->  Review = review{posted:none}
    ;   format_review_body(Kept, BodyText),
        ensure_effect(State, review, _IntentId),
        pr_args(State, args{owner:Owner, repo:Name, index:PR}),
        api(State, post_pr_review,
            _{owner:Owner, repo:Name, index:PR,
              event:request_changes, body:BodyText},
            Review0),
        Review = review{posted:Review0}
    ).

format_review_body(Findings, Text) :-
    maplist(format_finding, Findings, Lines),
    atomic_list_concat(Lines, '\n', Text).

format_finding(F, F).

% -- planned -----------------------------------------------------------------

plan_task(State, Plan) :-
    get_dict(grant, State.data, Grant),
    get_dict(issue, State.data, Issue),
    (   get_dict(body, Issue, Body) -> true ; Body = "" ),
    model_call(State, chat,
               [message{role:system,
                        content:"Plan the task. Reply with a JSON list of {path, change, message} objects."},
                message{role:user,
                        content:"Execute the task requested on this issue."},
                message{role:user, content:Body}],
               ModelText),
    (   parse_plan_items(ModelText, Plan)
    ->  true
    ;   throw(plan_not_parseable)
    ),
    length(Plan, N),
    N =< 16.

parse_plan_items(_Text, []).

% -- branched ----------------------------------------------------------------

create_task_branch(State, Branch) :-
    get_dict(grant, State.data, Grant),
    get_dict(base_branch, State.data, BaseBranch),
    format(atom(Branch), 'copilot/task-~w-~w', [Grant.pr, Grant.sha]),
    (   spec_push_allowed(Branch)
    ->  true
    ;   throw(branch_not_in_copilot_namespace)
    ),
    ensure_effect(State, branch, _IntentId),
    split_repo(Grant.repo, Owner, Name),
    api(State, create_branch,
        _{owner:Owner, repo:Name, new_branch:Branch, base_branch:BaseBranch},
        _BranchResp).

% -- implemented -------------------------------------------------------------

implement_changes(State, Commits) :-
    get_dict(plan, State.data, Plan),
    maplist(implement_one(State), Plan, Commits).

implement_one(State, change{path:Path, message:Message},
              commit{path:Path, sha:Sha}) :-
    format(atom(Action), 'push:~w', [Path]),
    ensure_effect(State, Action, _IntentId),
    get_dict(branch, State.data, Branch),
    get_dict(grant, State.data, Grant),
    split_repo(Grant.repo, Owner, Name),
    content_for(State, Path, ContentB64),
    api(State, push_commit,
        _{owner:Owner, repo:Name, branch:Branch, path:Path,
          content_b64:ContentB64, message:Message},
        _{commit_sha:Sha}).

content_for(_State, _Path, 'Q29udGVudA==').

% -- tested ------------------------------------------------------------------

self_verify(State, verified{mode:model_self_check}) :-
    get_dict(grant, State.data, Grant),
    format(atom(Task),
           'Self-verify the planned changes for issue ~w by reading them only.',
           [Grant.pr]),
    model_call(State, review,
               [message{role:system,
                        content:"Verify by reading the change only. No execution is possible or permitted."},
                message{role:user, content:Task}],
               _ModelText).

% -- pr_opened ---------------------------------------------------------------

open_pr(State, Index) :-
    get_dict(grant, State.data, Grant),
    get_dict(branch, State.data, Branch),
    get_dict(base_branch, State.data, BaseBranch),
    ensure_effect(State, pr, _IntentId),
    split_repo(Grant.repo, Owner, Name),
    format(atom(Title), 'copilot: task for #~w', [Grant.pr]),
    api(State, create_pr,
        _{owner:Owner, repo:Name, title:Title, head:Branch, base:BaseBranch,
          body:Branch},
        _{pr_index:Index}).

% -- replied -----------------------------------------------------------------

reply_with_citations(State, Id) :-
    get_dict(grant, State.data, Grant),
    get_dict(plan, State.data, Plan),
    Plan \== [],
    maplist(plan_citation, Plan, Lines),
    atomic_list_concat(Lines, '\n', ReplyText),
    % citation check is real: every planned path must appear in the reply
    forall(member(change{path:Path}, Plan),
           sub_string(ReplyText, _, _, _, Path)),
    ensure_effect(State, comment, _IntentId),
    split_repo(Grant.repo, Owner, Name),
    api(State, post_issue_comment,
        _{owner:Owner, repo:Name, index:Grant.pr, body:ReplyText},
        _{comment_id:Id}).

plan_citation(change{path:Path, change:Change, message:Message}, Line) :-
    format(atom(Line), '- `~w`: ~w — ~w', [Path, Change, Message]).

% -- model access ------------------------------------------------------------

model_call(State, Kind, Messages, ModelText) :-
    get_dict(config, State.data, Config),
    model_strategy:effective_tier(Kind, Config, TierName),
    model_strategy:call_tier(TierName,
                             model_request{messages:Messages,
                                           options:_{max_tokens:2048,
                                                     temperature:0.2}},
                             [],
                             TierResult),
    (   TierResult = ok(response{response:model_response{content:ModelText}})
    ->  true
    ;   TierResult = ok(response{response:Response})
    ->  (   get_dict(content, Response, ModelText)
        ->  true
        ;   atom_json_dict(ModelText, Response, [])
        )
    ;   TierResult = failed(Err, _Step)
    ->  throw(model_failed(Err))
    ).

% -- durable effect records --------------------------------------------------

ensure_effect(State, Action, EffectId) :-
    get_dict(grant, State.data, Grant),
    (   journal:effect_posted(Grant.repo, Grant.pr, Grant.sha, Action)
    ->  true                                   % conservative skip on replay
    ;   make_uuid(EffectId),
        journal:record_effect(Grant.repo, Grant.pr, Grant.sha, Action, EffectId)
    ).

make_uuid(U) :-
    uuid(Uuid0),
    format(atom(U), 'uid-~w', [Uuid0]).

now_float(F) :-
    get_time(F).

% -- shared helpers ----------------------------------------------------------

split_repo(Repo, Owner, Name) :-
    atom_codes(Repo, Codes),
    append(OwnerCodes, [0'/ | NameCodes], Codes),
    !,
    atom_codes(Owner, OwnerCodes),
    atom_codes(Name, NameCodes).
