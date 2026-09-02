:- module(copilot_graph,
          [ spec/1,
            registry/1,
            compile/1,
            node_step/4,
            route_step/3
          ]).

/** <module> Execution graph

The rlm_graph realization of the formal spec's abstract machine.

Structural mapping: the abstract terminals `done` and `failed` map to the
graph's single structural `end` node, distinguished by the closed state
field `status` (done|failed). A completed or failed rlm_graph run can never
be resumed (only paused runs resume), so both terminals are structurally
absorbing — `done` has no outgoing transitions and `failed` only
self-loops, per the spec invariants.

Handler protocol: trusted host code supplies a delegate module per run in
the state field `data` (as `data.delegate`). The delegate implements

    node(+Node, +State, +Context, -Outcome)

where Outcome is one of

  * ok(Patch)         — patch dict, may include route/reply data
  * failed(Error)     — the node failed; the run routes to the failed
                        terminal (absorbing)
  * interrupt(R, P)   — pause the run at this node; resume with R
*/

:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(library(rlm)).
:- use_module(library(lists)).

%% spec(-Spec) is det.
spec(graph(copilot_task,
           [ field(status, atom, running, replace),
             field(decision, atom, ok, replace),
             field(route, atom, none, replace),
             field(error, any, none, replace),
             field(log, list, [], append),
             field(data, any, none, replace)
           ],
           Nodes,
           Edges)) :-
    live_nodes(LiveNodes),
    maplist(node_entry, LiveNodes, Nodes),
    Edges = [edge(start, received) | LiveEdges],
    findall(Edge,
            (   member(N, LiveNodes),
                live_edge(N, Edge)
            ),
            LiveEdges).

live_nodes(LiveNodes) :-
    setof(N, spec_live_state(N), LiveNodes).

handler_id(N, HId) :-
    format(atom(HId), 'node_~w', [N]).
router_id(N, RId) :-
    format(atom(RId), 'route_~w', [N]).

node_entry(N, node(N, HId)) :-
    handler_id(N, HId).

%% registry(-Registry) is det.
registry(Registry) :-
    live_nodes(LiveNodes),
    findall(handler(HId, copilot_graph:node_step(N)),
            (   member(N, LiveNodes),
                handler_id(N, HId)
            ),
            Handlers),
    findall(router(RId, copilot_graph:route_step(N)),
            (   member(N, LiveNodes),
                router_id(N, RId)
            ),
            Routers),
    append(Handlers, Routers, Registry).

%% compile(-Compiled) is semidet.
compile(Compiled) :-
    spec(Spec),
    registry(Registry),
    rlm:graph_compile(Spec, Registry, [], ok(Compiled)).

% -- edge structure -----------------------------------------------------------

live_edge(received, Edge) :-
    edge(received, config_checked, Edge).
live_edge(config_checked, Edge) :-
    edge(config_checked, leased, Edge).
live_edge(leased, Edge) :-
    edge(leased, fetched, Edge).
live_edge(fetched, Edge) :-
    edge(fetched, partitioned, Edge).
live_edge(partitioned, conditional(partitioned, RId,
                                   [ route(review, reviewed),
                                     route(task, planned),
                                     route(failed, end)
                                   ])) :-
    router_id(partitioned, RId).
live_edge(reviewed, Edge) :-
    edge(reviewed, deduped, Edge).
live_edge(deduped, Edge) :-
    edge(deduped, posted, Edge).
live_edge(posted, Edge) :-
    terminal_edge(posted, Edge).
live_edge(planned, Edge) :-
    edge(planned, branched, Edge).
live_edge(branched, Edge) :-
    edge(branched, implemented, Edge).
live_edge(implemented, Edge) :-
    edge(implemented, tested, Edge).
live_edge(tested, Edge) :-
    edge(tested, pushed, Edge).
live_edge(pushed, Edge) :-
    edge(pushed, pr_opened, Edge).
live_edge(pr_opened, Edge) :-
    edge(pr_opened, replied, Edge).
live_edge(replied, Edge) :-
    terminal_edge(replied, Edge).

edge(From, To, conditional(From, RId,
                           [ route(next, To),
                             route(failed, end)
                           ])) :-
    router_id(From, RId).

terminal_edge(Node, conditional(Node, RId,
                                [ route(done, end),
                                  route(failed, end)
                                ])) :-
    router_id(Node, RId).

% -- trusted dispatchers (registry closures) -----------------------------------
% The delegate closure is trusted host configuration (per prolog-rlm
% doctrine), so outcome shapes are checked in a fixed order; a throw or an
% unrecognized outcome becomes a failed terminal, never a silent retry.

node_step(Node, State, Context, Result) :-
    delegate(State, Delegate),
    node_outcome(Delegate, Node, State, Context, Outcome),
    finalize(Node, Outcome, Result).

node_outcome(Delegate, Node, State, Context, Outcome) :-
    catch(call(Delegate:node(Node, State, Context, Result0)),
          Error, true),
    (   var(Error)
    ->  (   Result0 = ok(_)
        ->  Outcome = Result0
        ;   Result0 = failed(_)
        ->  Outcome = Result0
        ;   Result0 = interrupt(_, _)
        ->  Outcome = Result0
        ;   Outcome = failed(bad_outcome(Node))
        )
    ;   Outcome = failed(thrown(Error))
    ).

finalize(Node, ok(Patch0), update(Patch)) :-
    log_entry(Patch0, [node-Node], Logs0),
    Patch1 = Patch0.put(decision, ok).put(log, Logs0),
    (   terminal(Node)
    ->  Patch = Patch1.put(status, done)
    ;   Patch = Patch1
    ).
finalize(Node, failed(Reason0),
         update(patch{decision:failed,
                      status:failed,
                      error:Reason,
                      log:["failed" - Node]})) :-
    % thrown error terms may carry unbound context variables; the state
    % patch must be ground (rlm_graph requirement).
    ground_value(Reason0, Reason).
finalize(_Node, interrupt(Reason, Patch), interrupt(Reason, Patch)).

ground_value(Term, Ground) :-
    copy_term(Term, Ground),
    term_variables(Ground, Vars),
    forall(member(V, Vars), V = '$unbound').

terminal(posted).
terminal(replied).

route_step(_Node, State, failed) :-
    get_dict(decision, State, failed),
    !.
route_step(partitioned, State, Route) :-
    get_dict(route, State, StateRoute),
    member(StateRoute, [review, task]),
    !,
    Route = StateRoute.
route_step(posted, _State, done) :- !.
route_step(replied, _State, done) :- !.
route_step(_Node, _State, next).

delegate(State, Delegate) :-
    get_dict(data, State, Data),
    get_dict(delegate, Data, Delegate).

log_entry(Patch, Extra, Logs) :-
    (   get_dict(log, Patch, Log0)
    ->  append(Log0, Extra, Logs)
    ;   Logs = Extra
    ).
