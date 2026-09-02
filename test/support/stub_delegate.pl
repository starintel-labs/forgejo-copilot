:- module(stub_delegate,
          [ node/4
          ]).

/** <module> Stub delegate for deterministic graph tests

Configured through State.data:

  * fail_at(Atom)  — the node at which the delegate reports failure
  * route(atom)    — which branch partitioned takes (task|review)
*/

:- use_module(library(lists)).

node(partitioned, State, _Context, ok(patch{route:Route})) :-
    !,
    (   get_dict(grant, State.data, Grant),
        get_dict(route, Grant, Route)
    ->  true
    ;   get_dict(route, State.data, Route)
    ).
node(Node, State, _Context, failed(delegate_failed(Node))) :-
    get_dict(fail_at, State.data, Node),
    !.
node(Node, State, _Context, interrupt(pause(Node), patch{})) :-
    get_dict(interrupt_at, State.data, Node),
    !.
node(_Node, _State, _Context, ok(patch{})).
