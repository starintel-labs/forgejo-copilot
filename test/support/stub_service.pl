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
node(branched, State, _Context, ok(patch{data:Data})) :-
    !,
    api(State, create_branch, _{new_branch:'copilot/task-7'}, _),
    format(atom(Branch), 'copilot/task-~w', [State.data.grant.pr]),
    put_dict(branch, State.data, Branch, Data).
node(implemented, State, _Context, ok(patch{data:Data})) :-
    !,
    api(State, push_commit, _{path:'src/a.pl'}, _),
    put_dict(commits, State.data, [commit{path:'src/a.pl'}], Data).
node(pr_opened, State, _Context, ok(patch{data:Data})) :-
    !,
    api(State, create_pr, _{}, _),
    put_dict(pr_index, State.data, 42, Data).
node(replied, State, _Context, ok(patch{data:Data})) :-
    !,
    api(State, post_issue_comment, _{}, _),
    put_dict(comment_id, State.data, 99, Data).
node(_Node, _State, _Context, ok(patch{})).

api(State, Tool, Args, Value) :-
    get_dict(api, State.data, ApiCall),
    call(ApiCall, Tool, Args, Value).
