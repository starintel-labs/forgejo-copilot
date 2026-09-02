:- module(model_strategy,
          [ effective_tier/3,
            tier_chain/3,
            default_step_call/4,
            call_tier/4,
            downgrade_reason/1
          ]).

/** <module> Model strategy and downgrade chain

Implements the spec's model tiers and the mandatory downgrade order:

    openrouter_primary -> openrouter_alternate -> fallback_endpoint
    -> visible_failure_comment (terminal)

A step that answers 401, 429, 5xx, or an egress/transport failure
downgrades to the next step. Other provider errors fail the chain
immediately and the service posts a visible failure comment — the
terminal step of the chain. Never a silent failure.

The provider and model of every attempt are recorded in the effect
ledger (spend tracing) when a run id is supplied.
*/

:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(library(rlm)).
:- use_module(library(lists)).
:- use_module(library(option)).

%% effective_tier(+TriggerKind, +Config, -Tier) is det.
% /review always uses the review tier. Task execution uses the chat tier
% by default (model: fast) and upgrades to the review tier for
% model: strong. /ask is chat tier.
effective_tier(review, _Config, review).
effective_tier(task, Config, Tier) :-
    (   get_dict(model, Config, strong)
    ->  Tier = review
    ;   Tier = chat
    ).
effective_tier(ask, _Config, chat).

%% tier_chain(+Tier, +FallbackModel, -Steps) is det.
% Steps are ordered step{name, model, provider} dicts. The fallback
% provider is built only when its env vars exist; the model comes from
% FALLBACK_LLM_MODEL (default `default`).
tier_chain(Tier, FallbackModel, Steps) :-
    spec_model_tier(Tier, primary, PrimaryModel),
    spec_model_tier(Tier, alternate, AlternateModel),
    catch(rlm_chain:openrouter_provider(PrimaryModel, P1), _, fail),
    catch(rlm_chain:openrouter_provider(AlternateModel, P2), _, fail),
    Steps0 = [step{name:openrouter_primary, model:PrimaryModel, provider:P1},
              step{name:openrouter_alternate, model:AlternateModel, provider:P2}],
    (   getenv('FALLBACK_LLM_URL', Url),
        Url \== ''
    ->  (   getenv('FALLBACK_LLM_KEY', Key), Key \== ''
        ->  Credential = env('FALLBACK_LLM_KEY')
        ;   Credential = none
        ),
        catch(rlm_chain:openai_compatible_provider(Url, Credential,
                                                   FallbackModel, P3),
              _,
              fail),
        Steps = [step{name:fallback_endpoint, model:FallbackModel, provider:P3}
                 | Steps0]
    ;   Steps = Steps0
    ).

%% downgrade_reason(+Error) is semidet.
% 401/429/5xx provider failures and transport/egress errors downgrade.
% Key-tolerant: provider_error dicts may carry extra correlation fields.
downgrade_reason(Error) :-
    is_dict(Error, provider_error),
    get_dict(status, Error, Status),
    (   memberchk(Status, [401, 429, transport, egress])
    ;   integer(Status),
        Status >= 500,
        Status =< 599
    ).

%% call_tier(+Tier, +Request, +Options, -Result) is det.
% Options:
%   steps(Steps)           trusted host override of the concrete chain
%   fallback_model(Atom)   model name for the fallback endpoint (default default)
%   step_call(Pred4)       trusted host override for the HTTP step
%   run_id(RunId)          record provider+model per attempt in the journal
% Result:
%   ok(response{step_name, model, response})
%   failed(last_error, chain_exhausted)
call_tier(Tier, Request, Options, Result) :-
    (   option(steps(Steps), Options)
    ->  true
    ;   option(fallback_model(FbModel), Options, default),
        tier_chain(Tier, FbModel, Steps)
    ),
    call_chain(Steps, Request, Options, none, Result).

call_chain([], _Request, _Options, LastError,
           failed(LastError, chain_exhausted)).
call_chain([Step | Rest], Request, Options, LastError, Result) :-
    get_dict(name, Step, Name),
    get_dict(model, Step, Model),
    run_id_option(Options, RunId),
    (   RunId = run_id(R)
    ->  journal_spend_safe(R, attempted, Name, Model)
    ;   true
    ),
    step_call(Options, Step, Request, StepOutcome),
    (   StepOutcome = ok(Response)
    ->  (   RunId = run_id(R2)
        ->  journal_spend_safe(R2, used, Name, Model)
        ;   true
        ),
        Result = ok(response{step_name:Name, model:Model, response:Response})
    ;   StepOutcome = error(Err),
        downgrade_reason(Err)
    ->  call_chain(Rest, Request, Options, Err, Result)
    ;   StepOutcome = error(Err),
        Result = failed(Err, Name)
    ).

step_call(Options, Step, Request, Outcome) :-
    option(step_call(Pred4), Options),
    !,
    call(Pred4, Step, Request, [], Outcome).
step_call(_Options, Step, Request, Outcome) :-
    default_step_call(Step, Request, [], Outcome).

default_step_call(Step, Request, _Extra, Outcome) :-
    Provider = Step.provider,
    rlm_chain:model_complete(Provider, Request, Outcome).

run_id_option(Options, run_id(R)) :-
    option(run_id(R), Options),
    !.
run_id_option(_Options, none).

journal_spend_safe(RunId, Role, Name, Model) :-
    catch(journal:record_spend(RunId, Role, Name, Model),
          _, true).
