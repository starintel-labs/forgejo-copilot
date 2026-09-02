:- module(stub_service,
          [ node/4
          ]).

/** <module> Service-test delegate

Write nodes call the trusted API hook in State.data.api (mandatory in this
delegate's context — the restart fixture always supplies it). Other nodes
succeed. partitioned reads the route from data.grant.route.
*/

node(partitioned, State, _Context, ok(patch{route:Route})) :-
    get_dict(grant, State.data, Grant),
    get_dict(route, Grant, Route).
node(branched, State, _Context, ok(patch{branch:Branch})) :-
    !,
    api(State, create_branch, _{new_branch:'copilot/task-7'}, _),
    format(atom(Branch), 'copilot/task-~w', [State.data.grant.pr]).
node(implemented, State, _Context, ok(patch{commits:[commit{path:'src/a.pl'}]})) :-
    !,
    api(State, push_commit, _{path:'src/a.pl'}, _).
node(pr_opened, State, _Context, ok(patch{pr_index:42})) :-
    !,
    api(State, create_pr, _{}, _).
node(replied, State, _Context, ok(patch{comment_id:99})) :-
    !,
    api(State, post_issue_comment, _{}, _).
node(_Node, _State, _Context, ok(patch{})).

api(State, Tool, Args, Value) :-
    get_dict(api, State.data, ApiCall),
    call(ApiCall, Tool, Args, Value).
