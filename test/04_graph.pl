/* Execution graph — conformance with the formal spec and rlm_graph
   checkpoint/resume behavior. The abstract terminals done|failed map to
   the structural end node distinguished by state.status. */

:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(fcopilot(copilot_graph)).
:- use_module('support/stub_delegate.pl').
:- use_module('support/graph_fixtures.pl').

:- begin_tests(graph_conformance).

test(compiles) :-
    copilot_graph:compile(_Compiled).

test(realizes_spec_success_edges) :-
    copilot_graph:compile(Compiled),
    edges_of(Compiled, Edges),
    forall(task_step(From, To, Route),
           (   routes_from(Edges, From, Routes),
               member(Route-Target, Routes),
               spec_target(Target, To)
           )),
    forall(review_step(From, To, Route),
           (   routes_from(Edges, From, Routes),
               member(Route-Target, Routes),
               spec_target(Target, To)
           )).

task_step(received, config_checked, next).
task_step(config_checked, leased, next).
task_step(leased, fetched, next).
task_step(fetched, partitioned, next).
task_step(partitioned, planned, task).
task_step(planned, branched, next).
task_step(branched, implemented, next).
task_step(implemented, tested, next).
task_step(tested, pushed, next).
task_step(pushed, pr_opened, next).
task_step(pr_opened, replied, next).
task_step(replied, done, done).

review_step(partitioned, reviewed, review).
review_step(reviewed, deduped, next).
review_step(deduped, posted, next).
review_step(posted, done, done).

spec_target(end, done).
spec_target(T, T).

test(every_live_state_has_failure_route) :-
    copilot_graph:compile(Compiled),
    edges_of(Compiled, Edges),
    forall(forgejo_copilot_spec:spec_live_state(N),
           (   routes_from(Edges, N, Routes),
               member(failed-end, Routes)
           )).

test(end_has_no_outgoing) :-
    copilot_graph:compile(Compiled),
    edges_of(Compiled, Edges),
    \+ (   member(E, Edges),
           get_dict(from, E, end)
       ).

edges_of(Compiled, Compiled.edges).

routes_from(Edges, From, Pairs) :-
    member(E, Edges),
    get_dict(kind, E, conditional),
    get_dict(from, E, From),
    get_dict(routes, E, RouteDicts),
    findall(Key-Target,
            (   member(RD, RouteDicts),
                get_dict(key, RD, Key),
                get_dict(target, RD, Target)
            ),
            Pairs).

:- end_tests(graph_conformance).

:- begin_tests(graph_execution).


test(task_happy_path_reaches_done) :-
    copilot_graph:compile(Compiled),
    rlm:graph_backend_open(memory, Backend),
    graph_fixtures:initial_state(task, IS),
    setup_call_cleanup(
        rlm:graph_run(Compiled,
                      IS,
                      [backend(Backend), run_id(task_happy)],
                      ok(Completed)),
        true,
        rlm:graph_backend_close(Backend)),
    get_dict(status, Completed.state, done),
    get_dict(log, Completed.state, Log),
    graph_fixtures:log_nodes(Log, NodeList),
    graph_fixtures:task_chain(Chain),
    append(_, Chain, NodeList).

test(review_happy_path_reaches_done) :-
    copilot_graph:compile(Compiled),
    rlm:graph_backend_open(memory, Backend),
    graph_fixtures:initial_state(review, IS),
    setup_call_cleanup(
        rlm:graph_run(Compiled,
                      IS,
                      [backend(Backend), run_id(review_happy)],
                      ok(Completed)),
        true,
        rlm:graph_backend_close(Backend)),
    get_dict(status, Completed.state, done),
    get_dict(log, Completed.state, Log),
    graph_fixtures:log_nodes(Log, NodeList),
    graph_fixtures:review_chain(Chain),
    append(_, Chain, NodeList).

test(failure_at_node_reaches_absorbing_failed) :-
    copilot_graph:compile(Compiled),
    rlm:graph_backend_open(memory, Backend),
    setup_call_cleanup(
        rlm:graph_run(Compiled,
                      state{data:run_data{delegate:stub_delegate,
                                          route:task,
                                          fail_at:tested}},
                      [backend(Backend), run_id(task_fail)],
                      ok(Completed)),
        true,
        rlm:graph_backend_close(Backend)),
    get_dict(status, Completed.state, failed),
    get_dict(error, Completed.state, delegate_failed(tested)),
    % the failed terminal is absorbing: no resume of a completed run
    catch((   rlm:graph_resume(Compiled, Backend, task_fail, ignored, [],
                               R0)
          ->  ResumeCheck = R0
          ;   ResumeCheck = rejected
          ),
          _,
          ResumeCheck = rejected),
    \+ ResumeCheck = ok(_).

test(interrupt_pauses_and_resume_completes) :-
    copilot_graph:compile(Compiled),
    rlm:graph_backend_open(memory, Backend),
    setup_call_cleanup(
        (   rlm:graph_run(Compiled,
                          state{data:run_data{delegate:stub_delegate,
                                              route:task,
                                              interrupt_at:planned}},
                          [backend(Backend), run_id(task_pause)],
                          ok(Paused)),
            Paused.status == paused(pause(planned)),
            rlm:graph_checkpoint(Backend, task_pause, Snapshot),
            Snapshot.status == paused(pause(planned)),
            rlm:graph_resume(Compiled, Backend, task_pause, go, [],
                             ok(Completed))
        ),
        true,
        rlm:graph_backend_close(Backend)),
    get_dict(status, Completed.state, done).

:- end_tests(graph_execution).
