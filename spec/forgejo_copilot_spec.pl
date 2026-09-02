:- module(forgejo_copilot_spec,
          [ spec_schema_version/1,

            % -- execution-graph abstract machine -------------------------
            spec_graph_state/1,
            spec_live_state/1,
            spec_terminal_state/1,
            spec_transition/2,
            spec_success_edge/2,
            spec_failure_edge/1,
            spec_inv_done_terminal/0,
            spec_inv_failed_absorbent/0,
            spec_inv_live_can_fail/0,
            spec_inv_task_chain/0,
            spec_inv_review_chain/0,
            spec_inv_all_states_reach_terminal/0,

            % -- .copilot configuration semantics -------------------------
            spec_copilot_key/1,
            spec_copilot_default/2,
            spec_config_effective/2,
            spec_config_enabled/1,

            % -- trigger and admission gate -------------------------------
            spec_trigger/2,
            spec_actor_not_bot/1,
            spec_trigger_allowed/2,
            spec_eligible/6,
            spec_posted_effect_fact/1,
            spec_lease_fact/1,
            spec_lease_fenced/1,

            % -- authority ------------------------------------------------
            spec_branch_namespace/1,
            spec_protected_branch/1,
            spec_push_allowed/1,
            spec_push_denied/1,
            spec_never/1,
            spec_network_endpoint/1,
            spec_reply_requires_citation/0,

            % -- tool inventory -------------------------------------------
            spec_tool/4,
            spec_tool_names/2,
            spec_forbidden_tool/1,

            % -- model strategy -------------------------------------------
            spec_model_tier/3,
            spec_downgrade_step/2,
            spec_downgrade_terminal/1,
            spec_ledger_records_spend/0
          ]).

/** <module> forgejo-copilot formal specification

This module is the machine-checked contract for the service. It is pure: no
I/O, no side effects, no dependency on the runtime implementation. Facts
define vocabulary; rules define the verified invariants. PlUnit tests and
verify/verify.pl check the implementation against this module.

Provenance: invariants modelled after the FORGEJO-REVIEW-000 design session
(infra roam store, research/forgejo-reviewer). The battery encoded here is
re-run in this repository before and during implementation (test 01_spec,
verify/verify.pl). Nothing is claimed verified unless the battery runs.

== Abstract graph machine ==

States received..replied are live. Both terminals are abstract states:

  * done   — success terminal, no outgoing transitions
  * failed — absorbent failure state, only self-loops

Every live state can transition to failed. The task branch is

  received -> config_checked -> leased -> fetched -> partitioned ->
  planned -> branched -> implemented -> tested -> pushed -> pr_opened ->
  replied -> done

and the review branch replaces the tail with

  partitioned -> reviewed -> deduped -> posted -> done

In the rlm_graph realization both terminals map to the structural `end` node
distinguished by the closed state field `status` (done|failed). A completed
or failed rlm_graph run can never be resumed (only paused runs resume), so
both terminals are structurally absorbing; the abstract rules below remain
the contract and are checked by the test battery and verify script.
*/

spec_schema_version(1).

% ===========================================================================
% Abstract graph machine
% ===========================================================================

%% spec_terminal_state(?State) is nondet.
spec_terminal_state(done).
spec_terminal_state(failed).

%% spec_graph_state(?State) is nondet.
spec_graph_state(State) :-
    spec_success_edge(State, _).
spec_graph_state(State) :-
    spec_success_edge(_, State).
spec_graph_state(State) :-
    spec_terminal_state(State).

%% spec_live_state(?State) is nondet.
spec_live_state(State) :-
    spec_graph_state(State),
    \+ spec_terminal_state(State).

%% spec_success_edge(?From, ?To) is nondet.
% Task branch (primary trigger: @copilot executes the task).
spec_success_edge(received, config_checked).
spec_success_edge(config_checked, leased).
spec_success_edge(leased, fetched).
spec_success_edge(fetched, partitioned).
spec_success_edge(partitioned, planned).   % route: task
spec_success_edge(planned, branched).
spec_success_edge(branched, implemented).
spec_success_edge(implemented, tested).
spec_success_edge(tested, pushed).
spec_success_edge(pushed, pr_opened).
spec_success_edge(pr_opened, replied).
spec_success_edge(replied, done).
% Review branch (secondary command: /review).
spec_success_edge(partitioned, reviewed).  % route: review
spec_success_edge(reviewed, deduped).
spec_success_edge(deduped, posted).
spec_success_edge(posted, done).

%% spec_failure_edge(?From) is nondet.
% Every live state can go to failed.
spec_failure_edge(From) :-
    spec_live_state(From).

%% spec_transition(?From, ?To) is nondet.
% The complete abstract transition relation. done has no outgoing
% transitions; failed only self-loops.
spec_transition(From, To) :-
    spec_success_edge(From, To).
spec_transition(From, failed) :-
    spec_failure_edge(From).
spec_transition(failed, failed).

% -- invariant checkers (pure; run as the spec battery) ---------------------

spec_inv_done_terminal :-
    \+ spec_transition(done, _).

spec_inv_failed_absorbent :-
    forall(spec_transition(failed, T), T == failed),
    spec_transition(failed, failed).

spec_inv_live_can_fail :-
    forall(spec_live_state(S), spec_transition(S, failed)).

spec_inv_task_chain :-
    chain_holds([received, config_checked, leased, fetched, partitioned,
                 planned, branched, implemented, tested, pushed,
                 pr_opened, replied, done]).

spec_inv_review_chain :-
    chain_holds([partitioned, reviewed, deduped, posted, done]).

spec_inv_all_states_reach_terminal :-
    forall(spec_live_state(S), reach_terminal(S, [S])).

chain_holds([_]).
chain_holds([A, B | Rest]) :-
    spec_success_edge(A, B),
    chain_holds([B | Rest]).

reach_terminal(done, _) :- !.
reach_terminal(S, Seen) :-
    spec_transition(S, T),
    \+ member(T, Seen),
    (   spec_terminal_state(T)
    ;   reach_terminal(T, [T | Seen])
    ).

% ===========================================================================
% .copilot configuration semantics
% ===========================================================================
% The .copilot file is read from the PR BASE branch HEAD only. A .copilot
% added inside a PR branch never self-enables. The effective config is a
% closed dict; unknown file keys are ignored (forward compatible).

spec_copilot_key(enabled).
spec_copilot_key(model).
spec_copilot_key(auto).
spec_copilot_key(tasks).

spec_copilot_default(model, fast).
spec_copilot_default(auto, true).
spec_copilot_default(tasks, true).

%% spec_config_effective(+FileSpec, -Config) is semidet.
% FileSpec is `none` (no .copilot at the base HEAD) or a list of
% pairs(Key, Value) read from the base HEAD. Absent file disables the bot.
% Explicit enabled:false opts out. Presence without an enabled key means
% opted in (enabled:true). Defaults: model=fast, auto=true, tasks=true.
spec_config_effective(none,
                      config{enabled:false, model:fast, auto:true,
                             tasks:true}) :-
    !.
spec_config_effective(Pairs, Config) :-
    is_list(Pairs),
    !,
    (   memberchk(pairs(enabled, false), Pairs)
    ->  Enabled = false
    ;   memberchk(pairs(enabled, 'false'), Pairs)
    ->  Enabled = false
    ;   Enabled = true
    ),
    (   memberchk(pairs(model, Model), Pairs)
    ->  true
    ;   Model = fast
    ),
    (   memberchk(pairs(auto, Auto), Pairs)
    ->  true
    ;   Auto = true
    ),
    (   memberchk(pairs(tasks, Tasks), Pairs)
    ->  true
    ;   Tasks = true
    ),
    Config = config{enabled:Enabled, model:Model, auto:Auto, tasks:Tasks}.

%% spec_config_enabled(+Config) is semidet.
spec_config_enabled(Config) :-
    Config.enabled == true.

% ===========================================================================
% Trigger and admission gate
% ===========================================================================
% Event term (closed dict):
%   event{actor:Atom, actor_kind:human|bot, kind:mention, body:String}
%   event{actor:Atom, actor_kind:human|bot, kind:command,
%         command:'/review'|'/ask'}
%   event{actor:Atom, actor_kind:human|bot, kind:pr_opened}
%
% Ledger facts (pure list, ground terms):
%   spec_posted_effect_fact(posted_effect(Repo, PR, Sha))
%   spec_lease_fact(lease(Repo, PR, Token))

spec_posted_effect_fact(posted_effect(_Repo, _PR, _Sha)).
spec_lease_fact(lease(_Repo, _PR, _Token)).

%% spec_trigger(?Trigger, +Event) is semidet.
spec_trigger(mention, Event) :-
    Event.kind == mention.
spec_trigger(command(review), Event) :-
    Event.kind == command,
    Event.command == '/review'.
spec_trigger(command(ask), Event) :-
    Event.kind == command,
    Event.command == '/ask'.
spec_trigger(auto_review, Event) :-
    Event.kind == pr_opened.

%% spec_actor_not_bot(+Event) is semidet.
% Self-loop guard: bot-authored events (including the bot's own comments)
% never trigger anything.
spec_actor_not_bot(Event) :-
    Event.actor_kind \== bot.

%% spec_trigger_allowed(+Event, +Config) is semidet.
% @copilot mention requires tasks:true. /review and /ask are explicit human
% commands and require only enabled:true. Unattended auto-review of a newly
% opened PR requires auto:true.
spec_trigger_allowed(Event, Config) :-
    spec_trigger(mention, Event),
    Config.tasks == true.
spec_trigger_allowed(Event, _Config) :-
    spec_trigger(command(_), Event).
spec_trigger_allowed(Event, Config) :-
    spec_trigger(auto_review, Event),
    Config.auto == true.

%% spec_eligible(+Repo, +PR, +HeadSha, +Event, +Config, +Facts) is semidet.
% The full admission gate, evaluated against the effective .copilot config
% read from the PR base branch HEAD. Idempotency is keyed on
% (Repo, PR, HeadSha): a posted-effect fact for the same triple blocks
% re-admission; a force-push that changes HeadSha re-admits. One lease per
% (Repo, PR) must be free.
spec_eligible(Repo, PR, HeadSha, Event, Config, Facts) :-
    spec_config_enabled(Config),
    spec_actor_not_bot(Event),
    spec_trigger_allowed(Event, Config),
    \+ member(posted_effect(Repo, PR, HeadSha), Facts),
    \+ member(lease(Repo, PR, _), Facts).

%% spec_lease_fenced(+Facts) is det.
% Fencing: no (Repo, PR) pair carries two distinct concurrent leases.
spec_lease_fenced(Facts) :-
    \+ (   member(lease(R, P, T1), Facts),
           member(lease(R, P, T2), Facts),
           T1 \= T2
       ).

% ===========================================================================
% Authority
% ===========================================================================

%% spec_branch_namespace(-Prefix) is det.
% The bot may only create/push branches under this namespace.
spec_branch_namespace('copilot/').

%% spec_protected_branch(?Branch) is nondet.
% Protected branches are never pushed or modified by the bot.
spec_protected_branch(main).

%% spec_push_allowed(+Branch) is semidet.
spec_push_allowed(Branch) :-
    spec_branch_namespace(Prefix),
    atom_concat(Prefix, _Rest, Branch).

%% spec_push_denied(+Branch) is semidet.
spec_push_denied(Branch) :-
    \+ spec_push_allowed(Branch).

%% spec_never(?Absolute) is nondet.
% Hard authority absolutes. No configuration widens these.
spec_never(push_protected_branch).
spec_never(approve_own_pr).
spec_never(merge_own_pr).
spec_never(shell_tool).
spec_never(process_tool).
spec_never(model_call_unbounded).

%% spec_network_endpoint(?Role) is nondet.
% The complete network authority scope. Tools may not contact anything else.
spec_network_endpoint(forgejo_api).
spec_network_endpoint(openrouter).
spec_network_endpoint(fallback_llm).
spec_network_endpoint(brave_search).

%% spec_reply_requires_citation is det.
% Findings and replies must cite diff or file context; ungrounded replies
% are contract violations (threading itself is best-effort).
spec_reply_requires_citation.

% ===========================================================================
% Tool inventory (forgejo pack + web pack)
% ===========================================================================
% spec_tool(Pack, Name, Effect, Limits). Limits give per-tool wall-time and
% output-byte ceilings enforced by rlm_tool.

spec_tool(forgejo, list_issues_updated_since, read,
          _{time_limit:10.0, max_output_bytes:262144}).
spec_tool(forgejo, get_issue, read,
          _{time_limit:10.0, max_output_bytes:262144}).
spec_tool(forgejo, get_pr, read,
          _{time_limit:10.0, max_output_bytes:262144}).
spec_tool(forgejo, get_diff, read,
          _{time_limit:15.0, max_output_bytes:1048576}).
spec_tool(forgejo, list_changed_files, read,
          _{time_limit:10.0, max_output_bytes:262144}).
spec_tool(forgejo, get_comment_thread, read,
          _{time_limit:10.0, max_output_bytes:262144}).
spec_tool(forgejo, post_issue_comment, write,
          _{time_limit:10.0, max_output_bytes:8192}).
spec_tool(forgejo, post_pr_review, write,
          _{time_limit:10.0, max_output_bytes:65536}).
spec_tool(forgejo, create_branch, write,
          _{time_limit:10.0, max_output_bytes:8192}).
spec_tool(forgejo, push_commit, write,
          _{time_limit:30.0, max_output_bytes:65536}).
spec_tool(forgejo, create_pr, write,
          _{time_limit:10.0, max_output_bytes:8192}).
spec_tool(web, brave_search, read,
          _{time_limit:15.0, max_output_bytes:262144}).
spec_tool(web, web_fetch, read,
          _{time_limit:20.0, max_output_bytes:524288}).

%% spec_tool_names(?Pack, ?Name) is nondet.
spec_tool_names(Pack, Name) :-
    spec_tool(Pack, Name, _, _).

%% spec_forbidden_tool(?Kind) is nondet.
spec_forbidden_tool(shell).
spec_forbidden_tool(process).
spec_forbidden_tool(filesystem).
spec_forbidden_tool(arbitrary_network).

% ===========================================================================
% Model strategy and downgrade chain
% ===========================================================================
% Tier primaries and alternates; on 401/429/5xx/egress failure the chain
% downgrades primary -> alternate -> fallback endpoint -> visible failure
% comment. Never a silent failure. Every run records provider and model in
% the effect ledger for spend tracing.

spec_model_tier(review, primary, 'openai/5.6-sol').
spec_model_tier(review, alternate, 'z-ai/glm-5.3').
spec_model_tier(chat, primary, 'z-ai/5.3-flash').
spec_model_tier(chat, alternate, 'openai/5.6-luna').

%% spec_downgrade_step(?From, ?To) is nondet.
spec_downgrade_step(openrouter_primary, openrouter_alternate).
spec_downgrade_step(openrouter_alternate, fallback_endpoint).
spec_downgrade_step(fallback_endpoint, visible_failure_comment).

%% spec_downgrade_terminal(-Terminal) is det.
spec_downgrade_terminal(visible_failure_comment).

%% spec_ledger_records_spend is det.
spec_ledger_records_spend.
