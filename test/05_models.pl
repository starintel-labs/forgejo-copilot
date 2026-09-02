/* Model strategy — tier selection, downgrade chain order, and structured
   behavior on 401/429/5xx/egress vs other provider errors. Deterministic:
   the HTTP step is replaced by a trusted test closure. */

:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(fcopilot(model_strategy)).
:- use_module('support/model_fixtures.pl').

:- begin_tests(model_tiers).

test(effective_tier_by_command) :-
    model_fixtures:cfg(C0),
    model_strategy:effective_tier(review, C0, review),
    model_strategy:effective_tier(ask, C0, chat),
    model_strategy:effective_tier(task, C0, chat).

test(task_strong_upgrades_to_review_tier) :-
    C = config{enabled:true, model:strong, auto:true, tasks:true},
    model_strategy:effective_tier(task, C, review).

:- end_tests(model_tiers).

:- begin_tests(downgrade_reasons).

test(classification) :-
    model_strategy:downgrade_reason(provider_error{status:401}),
    model_strategy:downgrade_reason(provider_error{status:429}),
    model_strategy:downgrade_reason(provider_error{status:500}),
    model_strategy:downgrade_reason(provider_error{status:503}),
    model_strategy:downgrade_reason(provider_error{status:transport}),
    model_strategy:downgrade_reason(provider_error{status:egress}),
    \+ model_strategy:downgrade_reason(provider_error{status:400}),
    \+ model_strategy:downgrade_reason(provider_error{status:404}).

:- end_tests(downgrade_reasons).


:- begin_tests(downgrade_chain).

test(primary_success_no_downgrade) :-
    Table = [openrouter_primary-ok(good)],
    chain_options(Table, Options),
    model_strategy:call_tier(review, _R, Options, Result),
    Result = ok(Resp),
    get_dict(step_name, Resp, openrouter_primary),
    get_dict(model, Resp, openrouter_primary).

test(unauthorized_downgrades_to_alternate) :-
    Table = [openrouter_primary-error(provider_error{status:401}),
             openrouter_alternate-ok(good)],
    chain_options(Table, Options),
    model_strategy:call_tier(chat, _R, Options, ok(Resp)),
    get_dict(step_name, Resp, openrouter_alternate),
    get_dict(model, Resp, openrouter_alternate).

test(rate_limit_downgrades_to_fallback) :-
    Table = [openrouter_primary-error(provider_error{status:429}),
             openrouter_alternate-error(provider_error{status:429}),
             fallback_endpoint-ok(good)],
    chain_options(Table, Options),
    model_strategy:call_tier(chat, _R, Options, ok(Resp)),
    get_dict(step_name, Resp, fallback_endpoint).

test(tier_chain_carries_spec_models) :-
    model_strategy:tier_chain(review, default, Steps),
    member(S1, Steps),
    get_dict(name, S1, openrouter_primary),
    get_dict(model, S1, 'openai/5.6-sol'),
    member(S2, Steps),
    get_dict(name, S2, openrouter_alternate),
    get_dict(model, S2, 'z-ai/glm-5.3'),
    member(S3, Steps),
    get_dict(name, S3, openrouter_alternate),
    get_dict(model, S3, 'z-ai/glm-5.3').

test(egress_failure_downgrades) :-
    Table = [openrouter_primary-error(provider_error{status:transport}),
             openrouter_alternate-ok(good)],
    chain_options(Table, Options),
    model_strategy:call_tier(review, _R, Options, ok(Resp)),
    get_dict(step_name, Resp, openrouter_alternate).

test(all_downgrade_steps_fail_reaches_terminal) :-
    Table = [openrouter_primary-error(provider_error{status:401}),
             openrouter_alternate-error(provider_error{status:401}),
             fallback_endpoint-error(provider_error{status:401})],
    chain_options(Table, Options),
    model_strategy:call_tier(review, _R, Options, Result),
    Result = failed(provider_error{status:401}, chain_exhausted).

test(non_downgrade_error_fails_chain_immediately) :-
    model_fixtures:e400(openrouter_primary, E400),
    Table = [openrouter_primary-E400,
             openrouter_alternate-ok(never)],
    chain_options(Table, Options),
    model_strategy:call_tier(review, _R, Options, Result),
    Result = failed(provider_error{status:400,
                                   from:openrouter_primary},
                    openrouter_primary).

test(fallback_500_downgrades_to_visible_failure) :-
    Table = [openrouter_primary-error(provider_error{status:503}),
             openrouter_alternate-error(provider_error{status:503}),
             fallback_endpoint-error(provider_error{status:500,
                                                    from:fallback_endpoint})],
    chain_options(Table, Options),
    model_strategy:call_tier(chat, _R, Options,
                             failed(provider_error{status:500,
                                                   from:fallback_endpoint},
                                    chain_exhausted)).

:- end_tests(downgrade_chain).

:- begin_tests(chain_order).

test(spec_chain_order) :-
    findall(A-B, forgejo_copilot_spec:spec_downgrade_step(A, B), Pairs),
    Pairs == [openrouter_primary-openrouter_alternate,
              openrouter_alternate-fallback_endpoint,
              fallback_endpoint-visible_failure_comment],
    forgejo_copilot_spec:spec_downgrade_terminal(visible_failure_comment).

:- end_tests(chain_order).
