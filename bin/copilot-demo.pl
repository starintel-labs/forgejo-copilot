/* bin/copilot-demo.pl — credential-free smoke walkthrough.

   Run: swipl -q -s bin/copilot-demo.pl

   Drives one @copilot mention event through the real pipeline —
   admit (spec admission gate) -> rlm_graph run -> done — with a stub
   delegate (bin/demo_delegate.pl) and a fake Forgejo API hook. No
   environment, no network, no credentials: all Forgejo responses come
   from demo_api/3 and all durable state lives in a throwaway temp
   directory that is removed at the end. Prints a short structured
   summary and exits 0; any drift from the expected outcome exits
   nonzero.
*/

:- prolog_load_context(source, File),
   file_directory_name(File, Dir),
   format(atom(BinDir), '~w', [Dir]),
   format(atom(ParentDir), '~w/..', [Dir]),
   assertz(user:file_search_path(demo_bin, BinDir)),
   assertz(user:file_search_path(demo_root, ParentDir)),
   true.

:- use_module(demo_root('test/loader.pl')).

:- initialization(main, main).

%% -- main ---------------------------------------------------------------------

main(_Argv) :-
    fcopilot_loader:setup_paths,
    fcopilot_loader:load_copilot,
    use_module(library(lists)),
    use_module(demo_bin(demo_delegate)),
    tmp_state_dir(StateDir),
    setup_call_cleanup(
        true,
        (   run_once(StateDir),
            reprocess_refused(StateDir)
        ),
        catch(delete_directory_and_contents(StateDir), _, true)),
    halt(0).

%% run_once(+StateDir) is det.
% Admit one mention event and run the graph to done.
run_once(StateDir) :-
    Options = [state_dir(StateDir),
               delegate(demo_delegate),
               api(demo_api)],
    polled_event(Polled),
    mention_event(Event),
    service:process_event('demo/repo', Polled, Event,
                          'demo/repo:7:sha1:demo', Options),
    service:init(Options),
    \+ journal:lease_held('demo/repo', 7, _),
    journal:effect_posted('demo/repo', 7, sha1),
    journal:facts(Facts),
    demo_writes(Writes),
    Writes == 4,
    format('demo: mention admitted; graph ran to done~n'),
    format('demo: journal facts: ~w~n', [Facts]),
    format('demo: side effects recorded exactly once (~w writes)~n',
           [Writes]).

%% reprocess_refused(+StateDir) is det.
% Re-processing the same event must hit the posted-effect refusal; no
% new side effects may appear.
reprocess_refused(StateDir) :-
    Options = [state_dir(StateDir),
               delegate(demo_delegate),
               api(demo_api)],
    demo_writes(Before),
    polled_event(Polled),
    mention_event(Event),
    service:process_event('demo/repo', Polled, Event,
                          'demo/repo:7:sha1:demo', Options),
    demo_writes(After),
    Before == After,
    format('demo: re-poll refused (already_done) — exactly once~n').

%% -- fake Forgejo hook ---------------------------------------------------------
% Trusted test double for service's api hook; answers every call the
% delegate makes without touching a network. Write calls are counted in
% a dynamic predicate so the summary can prove exactly-once.

:- dynamic demo_write/1.

demo_api(get_issue, Args,
         issue{number:N, body:"@copilot fix the parser bug",
               user:login{login:"alice"}}) :-
    (   get_dict(index, Args, N) -> true ; N = 7 ),
    !.
demo_api(get_comment_thread, _, _{comments:[]}) :- !.
demo_api(get_pr, _, _) :- !, fail.
demo_api(get_file_content, _, _{text:"enabled: true\n"}) :- !.
demo_api(create_branch, _, branch{name:'copilot/task-7'}) :- !,
    record_write(branch).
demo_api(push_commit, _{path:P}, _{commit_sha:sha(P)}) :- !,
    record_write(push).
demo_api(create_pr, _, _{pr_index:42}) :- !,
    record_write(pr).
demo_api(post_issue_comment, _, _{comment_id:99}) :- !,
    record_write(reply).

record_write(Kind) :-
    assertz(demo_write(Kind)).

demo_writes(N) :-
    aggregate_all(count, demo_write(_), N).

%% -- temp state ---------------------------------------------------------------

tmp_state_dir(Dir) :-
    current_prolog_flag(pid, Pid),
    get_time(T),
    (   getenv('TMPDIR', T0), T0 \== ''
    ->  true
    ;   T0 = '/tmp'
    ),
    format(atom(Dir), '~w/fcopilot-demo-~w-~w', [T0, Pid, T]),
    catch(delete_directory_and_contents(Dir), _, true),
    make_directory_path(Dir).

%% -- fixture event ------------------------------------------------------------

mention_event(event{actor:alice, actor_kind:human, kind:mention,
                    body:'@copilot fix the parser bug'}).

polled_event(polled{repo:'demo/repo', pr:7, sha:sha1,
                    login:'alice', bot:false,
                    body:'@copilot fix the parser bug',
                    kind_hint:comment, event_id:demo}).
