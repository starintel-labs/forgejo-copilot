/* Port of the FORGEJO-REVIEW-000 invariant battery against the formal spec.
   These tests must pass before any implementation module is written. */

:- use_module(fcopilot_spec(forgejo_copilot_spec)).

:- begin_tests(spec_machine, []).

test(done_has_no_outgoing_transitions) :-
    \+ forgejo_copilot_spec:spec_transition(done, _).

test(failed_only_self_loops) :-
    forall(forgejo_copilot_spec:spec_transition(failed, T), T == failed),
    forgejo_copilot_spec:spec_transition(failed, failed).

test(every_live_state_can_fail) :-
    forall(forgejo_copilot_spec:spec_live_state(S),
           forgejo_copilot_spec:spec_transition(S, failed)).

test(full_task_chain_exists) :-
    once(chain_holds([received, config_checked, leased, fetched, partitioned,
                      planned, branched, implemented, tested, pushed,
                      pr_opened, replied, done])).

test(review_chain_exists) :-
    once(chain_holds([partitioned, reviewed, deduped, posted, done])).

test(all_live_states_reach_a_terminal) :-
    forall(forgejo_copilot_spec:spec_live_state(S),
           once(reaches_terminal(S, [S]))).

chain_holds([_]).
chain_holds([A, B | Rest]) :-
    forgejo_copilot_spec:spec_success_edge(A, B),
    chain_holds([B | Rest]).

reaches_terminal(done, _) :- !.
reaches_terminal(S, Seen) :-
    forgejo_copilot_spec:spec_transition(S, T),
    \+ member(T, Seen),
    (   forgejo_copilot_spec:spec_terminal_state(T)
    ;   reaches_terminal(T, [T | Seen])
    ).

:- end_tests(spec_machine).

:- begin_tests(spec_admission, []).

cfg(config{enabled:true, model:fast, auto:true, tasks:true}).

mention(Event) :-
    Event = event{actor:alice, actor_kind:human, kind:mention,
                  body:'@copilot fix the parser bug'}.

test(mention_admits) :-
    cfg(C), mention(E),
    forgejo_copilot_spec:spec_eligible('org/repo', 7, sha1, E, C, []).

test(same_repo_pr_sha_blocked_by_posted_effect) :-
    cfg(C), mention(E),
    \+ forgejo_copilot_spec:spec_eligible('org/repo', 7, sha1, E, C,
                                          [posted_effect('org/repo', 7, sha1)]).

test(force_push_new_sha_readmits) :-
    cfg(C), mention(E),
    forgejo_copilot_spec:spec_eligible('org/repo', 7, sha2, E, C,
                                       [posted_effect('org/repo', 7, sha1)]).

test(bot_authored_mention_ignored) :-
    cfg(C),
    E = event{actor:copilot, actor_kind:bot, kind:mention, body:'@copilot hi'},
    \+ forgejo_copilot_spec:spec_eligible('org/repo', 7, sha1, E, C, []).

test(bot_authored_command_ignored) :-
    cfg(C),
    E = event{actor:copilot, actor_kind:bot, kind:command, command:'/review'},
    \+ forgejo_copilot_spec:spec_eligible('org/repo', 7, sha1, E, C, []).

test(absent_copilot_file_disables) :-
    forgejo_copilot_spec:spec_config_effective(none, C),
    C.enabled == false.

test(explicit_enabled_false_opts_out) :-
    forgejo_copilot_spec:spec_config_effective([pairs(enabled, false)], C),
    C.enabled == false.

test(config_defaults) :-
    forgejo_copilot_spec:spec_config_effective([pairs(enabled, true)], C),
    C.model == fast,
    C.auto == true,
    C.tasks == true.

test(unknown_copilot_keys_ignored) :-
    forgejo_copilot_spec:spec_config_effective(
        [pairs(enabled, true), pairs(bogus, 42)], C),
    C.enabled == true.

test(tasks_false_blocks_mention_but_not_commands) :-
    C = config{enabled:true, model:fast, auto:true, tasks:false},
    E1 = event{actor:a, actor_kind:human, kind:mention, body:'@copilot do it'},
    \+ forgejo_copilot_spec:spec_eligible('o/r', 1, s, E1, C, []),
    E2 = event{actor:a, actor_kind:human, kind:command, command:'/review'},
    forgejo_copilot_spec:spec_eligible('o/r', 1, s, E2, C, []),
    E3 = event{actor:a, actor_kind:human, kind:command, command:'/ask'},
    forgejo_copilot_spec:spec_eligible('o/r', 1, s, E3, C, []).

test(auto_false_blocks_unattended_pr_opened) :-
    C = config{enabled:true, model:fast, auto:false, tasks:true},
    E = event{actor:a, actor_kind:human, kind:pr_opened},
    \+ forgejo_copilot_spec:spec_trigger_allowed(E, C).

test(active_lease_blocks_admission) :-
    cfg(C), mention(E),
    \+ forgejo_copilot_spec:spec_eligible('org/repo', 7, sha1, E, C,
                                          [lease('org/repo', 7, tokA)]).

test(lease_fencing_one_lease_per_repo_pr) :-
    forgejo_copilot_spec:spec_lease_fenced([lease('o/r', 1, t1),
                                            lease('o/r', 2, t2)]),
    \+ forgejo_copilot_spec:spec_lease_fenced([lease('o/r', 1, t1),
                                               lease('o/r', 1, t2)]).

:- end_tests(spec_admission).

:- begin_tests(spec_authority, []).

test(pushes_only_under_copilot_namespace) :-
    forgejo_copilot_spec:spec_push_allowed('copilot/fix-parser-7'),
    forgejo_copilot_spec:spec_push_allowed('copilot/x/y'),
    forgejo_copilot_spec:spec_push_denied(main),
    forgejo_copilot_spec:spec_push_denied('feature/copilot-like'),
    forgejo_copilot_spec:spec_push_denied('').

test(main_is_protected) :-
    forgejo_copilot_spec:spec_protected_branch(main).

test(hard_never_list) :-
    forgejo_copilot_spec:spec_never(approve_own_pr),
    forgejo_copilot_spec:spec_never(merge_own_pr),
    forgejo_copilot_spec:spec_never(push_protected_branch),
    forgejo_copilot_spec:spec_never(shell_tool),
    forgejo_copilot_spec:spec_never(process_tool).

test(network_scope_is_closed) :-
    findall(E, forgejo_copilot_spec:spec_network_endpoint(E), Endpoints),
    msort(Endpoints, [brave_search, fallback_llm, forgejo_api, openrouter]).

test(no_shell_or_process_tools_registered) :-
    forall(forgejo_copilot_spec:spec_tool_names(_Pack, Name),
           \+ memberchk(Name, [shell, process, exec, spawn])).

test(every_tool_has_ceilings) :-
    forall(forgejo_copilot_spec:spec_tool(_P, _N, _E, Limits),
           (   get_dict(time_limit, Limits, T), T > 0,
               get_dict(max_output_bytes, Limits, B), B > 0
           )).

test(every_tool_declares_known_effect) :-
    forall(forgejo_copilot_spec:spec_tool(_P, _N, Effect, _L),
           member(Effect, [read, write])).

:- end_tests(spec_authority).

:- begin_tests(spec_models, []).

test(review_tier_models) :-
    forgejo_copilot_spec:spec_model_tier(review, primary, 'openai/5.6-sol'),
    forgejo_copilot_spec:spec_model_tier(review, alternate, 'z-ai/glm-5.3').

test(chat_tier_models) :-
    forgejo_copilot_spec:spec_model_tier(chat, primary, 'z-ai/5.3-flash'),
    forgejo_copilot_spec:spec_model_tier(chat, alternate, 'openai/5.6-luna').

test(downgrade_chain_reaches_visible_failure) :-
    once(chain_reaches(openrouter_primary, visible_failure_comment)),
    \+ forgejo_copilot_spec:spec_downgrade_step(X, X).

chain_reaches(S, T) :-
    forgejo_copilot_spec:spec_downgrade_step(S, T).
chain_reaches(S, T) :-
    forgejo_copilot_spec:spec_downgrade_step(S, Mid),
    chain_reaches(Mid, T).

:- end_tests(spec_models).
