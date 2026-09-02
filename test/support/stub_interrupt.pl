:- module(stub_interrupt,
          [ node/4
          ]).

/** <module> Test delegate: interrupts the run at `planned` */

node(partitioned, State, _Context, ok(patch{route:Route})) :-
    get_dict(route, State.data.grant, Route).
node(planned, _State, _Context, interrupt(pause(planned), patch{})) :- !.
node(_Node, _State, _Context, ok(patch{})).
