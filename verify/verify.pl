/* verify/verify.pl — spec-vs-implementation conformance gate.

   Run: swipl -q -s verify/verify.pl

   Exit 0 when the implementation conforms to spec/forgejo_copilot_spec.pl;
   exit 1 on any drift. Checks:

     1. the compiled rlm_graph realization realizes every spec transition
        (terminals done/failed via the structural end node + status field),
        every live state has a failure route, and end has no outgoing edges;
     2. the registered tool schemas match spec_tool/4 names/effects/ceilings
        exactly and carry no shell/process/arbitrary-network capability;
     3. the authority absolutes hold (spec_push_allowed closure, the pinned
        spec_never set, the closed spec_network_endpoint scope);
     4. model tiers and the downgrade chain match spec_model_tier/3 and
        spec_downgrade_step/2, in the spec's execution order.
*/

:- use_module('../test/loader.pl').

:- initialization(main, main).

main(_Argv) :-
    fcopilot_loader:setup_paths,
    fcopilot_loader:load_copilot,
    use_module(fcopilot_spec(forgejo_copilot_spec)),
    use_module(library(rlm_tool_loader)),
    use_module(library(lists)),
    forall(verify_check(Name, Goal), run_check(Name, Goal)),
    length_checks(Total),
    (   \+ drift
    ->  format('verify: conformance gate passed (~w checks)~n', [Total]),
        halt(0)
    ;   format('verify: CONFORMANCE DRIFT (see FAIL lines)~n', []),
        halt(1)
    ).

length_checks(Total) :-
    aggregate_all(count, verify_check(_, _), Total).

:- dynamic drift/0.

run_check(Name, Goal) :-
    (   catch(Goal, Error, (format('FAIL ~w (threw ~w)~n', [Name, Error]), fail))
    ->  format('ok   ~w~n', [Name])
    ;   format('FAIL ~w~n', [Name]),
        assertz(drift)
    ).

%% verify_check(?Name, :Goal) is nondet.
verify_check(graph_compiles, copilot_graph:compile(_Compiled)).
verify_check(graph_node_set_matches_spec, graph_node_set_matches_spec).
verify_check(graph_success_edges_realized, forall(spec_success_edge(F, T),
                                                  graph_edge_realized(F, T))).
verify_check(graph_failure_route_everywhere,
             forall(spec_live_state(S), graph_failure_route(S))).
verify_check(graph_done_terminal_routes,
             forall(spec_success_edge(S, done), graph_done_route(S))).
verify_check(graph_end_absorbing, \+ graph_edge_from_end).
verify_check(graph_no_spec_terminal_nodes,
             \+ (graph_node(N), spec_terminal_state(N))).

verify_check(tools_match_spec_names_effects_ceilings, tools_match_spec).
verify_check(tools_no_extra, tools_no_extra).
verify_check(tools_no_forbidden_capability, tools_no_forbidden_capability).

verify_check(push_namespace_closure, push_namespace_closure).
verify_check(spec_never_pinned, spec_never_pinned).
verify_check(network_scope_pinned, network_scope_pinned).
verify_check(tools_network_closure, tools_network_closure).

verify_check(model_tier_selection, model_tier_selection).
verify_check(tier_models_match_spec, tier_models_match_spec).
verify_check(downgrade_edges_pinned, downgrade_edges_pinned).
verify_check(chain_order_matches_spec, chain_order_matches_spec).

% -- graph --------------------------------------------------------------------
% rlm normalizes the compiled graph into dicts:
%   graph_node{name, kind, ref}
%   graph_edge{from, kind:fixed, to}
%   graph_edge{from, kind:conditional, router, routes:[route{key, target}]}

graph_compiled(C) :- copilot_graph:compile(C).

graph_node(N) :-
    graph_compiled(C),
    member(Node, C.nodes),
    get_dict(name, Node, N).

graph_fixed_edge(F, T) :-
    graph_compiled(C),
    member(E, C.edges),
    get_dict(from, E, F),
    get_dict(kind, E, fixed),
    get_dict(to, E, T).

graph_conditional_edge(F, Routes) :-
    graph_compiled(C),
    member(E, C.edges),
    get_dict(from, E, F),
    get_dict(kind, E, conditional),
    get_dict(routes, E, Routes).

graph_route_target(Routes, Key, Target) :-
    member(Route, Routes),
    get_dict(key, Route, Key),
    get_dict(target, Route, Target).

graph_edge_realized(F, done) :- !,
    graph_done_route(F).
graph_edge_realized(F, failed) :- !,
    graph_failure_route(F).
graph_edge_realized(F, T) :-
    (   graph_fixed_edge(F, T)
    ;   graph_conditional_edge(F, Routes),
        graph_route_target(Routes, _, T)
    ).

graph_failure_route(S) :-
    graph_conditional_edge(S, Routes),
    graph_route_target(Routes, failed, end).

graph_done_route(S) :-
    graph_conditional_edge(S, Routes),
    graph_route_target(Routes, done, end).

graph_edge_from_end :-
    (   graph_fixed_edge(end, _)
    ;   graph_conditional_edge(end, _)
    ).

graph_node_set_matches_spec :-
    findall(N, spec_live_state(N), Live0),
    sort(Live0, Live),
    findall(N, graph_node(N), Nodes0),
    sort(Nodes0, Nodes0S),
    (   select(end, Nodes0S, LiveFromGraph)
    ->  true
    ;   LiveFromGraph = Nodes0S
    ),
    Live == LiveFromGraph.

% -- tool registry ------------------------------------------------------------

registered_schemas(Schemas) :-
    rlm_tool:tool_registry_create(Registry),
    setup_call_cleanup(
        (   rlm_tool_loader:rlm_load_tools(Registry, forgejo, ok(_)),
            rlm_tool_loader:rlm_load_tools(Registry, web, ok(_))
        ),
        rlm_tool:tool_discover(Registry, Schemas),
        rlm_tool:tool_registry_destroy(Registry)).

schema_for(Name, Schema) :-
    registered_schemas(Schemas),
    member(Schema, Schemas),
    get_dict(name, Schema, Name).

tools_match_spec :-
    forall(spec_tool(Pack, Name, Effect, Limits),
           (   schema_for(Name, Schema),
               get_dict(effect, Schema, Effect),
               get_dict(limits, Schema, ToolLimits),
               get_dict(time_limit, Limits, SpecTime),
               get_dict(time_limit, ToolLimits, ToolTime),
               SpecTime == ToolTime,
               get_dict(max_output_bytes, Limits, SpecBytes),
               get_dict(max_output_bytes, ToolLimits, ToolBytes),
               SpecBytes == ToolBytes,
               spec_tool_pack(Name, Pack)
           )).

spec_tool_pack(Name, Pack) :-
    spec_tool(Pack, Name, _, _).

tools_no_extra :-
    registered_schemas(Schemas),
    forall(member(S, Schemas),
           (   get_dict(name, S, Name),
               spec_tool_names(_, Name)
           )).

tools_no_forbidden_capability :-
    registered_schemas(Schemas),
    forall(member(S, Schemas),
           (   get_dict(name, S, Name),
               get_dict(capability, S, tool(Name)),
               \+ forbidden_tool_name(Name),
               forall(schema_argument_key(S, Key),
                      (   \+ member(Key, [command, argv, script, shell,
                                          exec, cwd, stdin, stdout,
                                          pid, timeout_kill]),
                          (   member(Key, [url, host, endpoint, base_url])
                          ->  Name == web_fetch        % the guarded fetcher
                          ;   true
                          )
                      ))
           )).

forbidden_tool_name(Name) :-
    member(Name, [shell, process, exec, run, spawn, system, eval,
                  shell_tool, process_tool]).

schema_argument_key(Schema, Key) :-
    get_dict(arguments, Schema, Arguments),
    is_dict(Arguments),
    dict_pairs(Arguments, _, Pairs),
    member(Key-_, Pairs).
% argument schemas are nested dicts of typed slots; keys also appear inside
% nested item dicts.
schema_argument_key(Schema, Key) :-
    get_dict(arguments, Schema, Arguments),
    is_dict(Arguments),
    dict_pairs(Arguments, _, Pairs),
    member(_-Value, Pairs),
    is_dict(Value),
    dict_pairs(Value, _, Inner),
    member(Key-_, Inner).

% -- authority ----------------------------------------------------------------

push_namespace_closure :-
    spec_push_allowed('copilot/task-7'),
    spec_push_allowed('copilot/x'),
    \+ spec_push_allowed(main),
    \+ spec_push_allowed('release/x'),
    \+ spec_push_allowed(''),
    forall(spec_protected_branch(B), \+ spec_push_allowed(B)).

spec_never_pinned :-
    findall(N, spec_never(N), Never0),
    sort(Never0, Never),
    Never == [approve_own_pr, merge_own_pr, model_call_unbounded,
              process_tool, push_protected_branch, shell_tool].

network_scope_pinned :-
    findall(E, spec_network_endpoint(E), Endpoints0),
    sort(Endpoints0, Endpoints),
    Endpoints == [brave_search, fallback_llm, forgejo_api, openrouter].

tools_network_closure :-
    % No tool argument grants arbitrary-network authority: exactly one
    % tool (the SSRF-guarded web fetcher) may accept a URL-shaped argument.
    registered_schemas(Schemas),
    forall(member(S, Schemas),
           (   get_dict(name, S, Name),
               findall(Key, schema_argument_key(S, Key), Keys0),
               sort(Keys0, Keys),
               (   member(K, Keys),
                   member(K, [url, host, endpoint, base_url])
               ->  Name == web_fetch
               ;   true
               )
           )).

% -- model strategy -----------------------------------------------------------

model_tier_selection :-
    C0 = config{enabled:true, model:fast, auto:true, tasks:true},
    C1 = config{enabled:true, model:strong, auto:true, tasks:true},
    model_strategy:effective_tier(review, C0, review),
    model_strategy:effective_tier(ask, C0, chat),
    model_strategy:effective_tier(task, C0, chat),
    model_strategy:effective_tier(task, C1, review).

tier_models_match_spec :-
    tier_chain_steps(review, StepsR),
    steps_names_models(StepsR, [openrouter_primary-'openai/5.6-sol',
                                openrouter_alternate-'z-ai/glm-5.3']),
    tier_chain_steps(chat, StepsC),
    steps_names_models(StepsC, [openrouter_primary-'z-ai/5.3-flash',
                                openrouter_alternate-'openai/5.6-luna']).

steps_names_models([], []).
steps_names_models([S | Ss], [Name-Model | Rest]) :-
    get_dict(name, S, Name),
    get_dict(model, S, Model),
    steps_names_models(Ss, Rest).

tier_chain_steps(Tier, Steps) :-
    with_fallback_env(unset,
                      model_strategy:tier_chain(Tier, default, Steps)).

downgrade_edges_pinned :-
    findall(A-B, spec_downgrade_step(A, B), Pairs0),
    sort(Pairs0, Pairs),
    Pairs == [fallback_endpoint-visible_failure_comment,
              openrouter_alternate-fallback_endpoint,
              openrouter_primary-openrouter_alternate],
    spec_downgrade_terminal(visible_failure_comment).

chain_order_matches_spec :-
    with_fallback_env(set,
                      (   model_strategy:tier_chain(review, 'fb-model', Steps),
                          steps_names(Steps, Names),
                          Names == [openrouter_primary,
                                    openrouter_alternate,
                                    fallback_endpoint]
                      )),
    with_fallback_env(unset,
                      (   model_strategy:tier_chain(chat, default, Steps2),
                          steps_names(Steps2, Names2),
                          Names2 == [openrouter_primary, openrouter_alternate]
                      )).

steps_names([], []).
steps_names([S | Ss], [Name | Rest]) :-
    get_dict(name, S, Name),
    steps_names(Ss, Rest).

% The fallback endpoint is configured only through the environment; the
% verify gate exercises both branches deterministically.
with_fallback_env(Mode, Goal) :-
    (   getenv('FALLBACK_LLM_URL', SavedUrl)
    ->  true
    ;   SavedUrl = unset
    ),
    (   getenv('FALLBACK_LLM_KEY', SavedKey)
    ->  true
    ;   SavedKey = unset
    ),
    setup_call_cleanup(
        apply_fallback_mode(Mode),
        Goal,
        restore_fallback_env(SavedUrl, SavedKey)).

apply_fallback_mode(set) :-
    setenv('FALLBACK_LLM_URL', 'http://127.0.0.1:9/v1'),
    setenv('FALLBACK_LLM_KEY', 'verify-dummy-key').
apply_fallback_mode(unset) :-
    setenv('FALLBACK_LLM_URL', '').

restore_fallback_env(unset, _) :-
    unsetenv('FALLBACK_LLM_URL'),
    unsetenv('FALLBACK_LLM_KEY').
restore_fallback_env(SavedUrl, SavedKey) :-
    setenv('FALLBACK_LLM_URL', SavedUrl),
    (   SavedKey == unset
    ->  unsetenv('FALLBACK_LLM_KEY')
    ;   setenv('FALLBACK_LLM_KEY', SavedKey)
    ).
