:- module(admission,
          [ admit/7,
            admit_reason/7
          ]).

/** <module> Admission gate

Pure realization of the spec admission gate. The caller supplies the
effective `.copilot` config (which must have been read from the PR base
branch HEAD only) and a list of world facts: `posted_effect(Repo, PR, Sha)`
and `lease(Repo, PR, Token)` entries from the durable journal. Claiming a
lease and recording effects are separate journal operations owned by the
service loop — this module decides admission only.

admit(+Repo, +PR, +Sha, +Event, +Config, +Facts, -Result)

Result is `ok(Grant)` where Grant is a dict with `repo`, `pr`, `sha`,
`event`, `config`, and `route` (task|review), or the gate refuses and the
predicate fails without any observable effect.
*/

:- use_module(fcopilot_spec(forgejo_copilot_spec)).

admit(Repo, PR, Sha, Event, Config, Facts, ok(Grant)) :-
    admit_reason(Repo, PR, Sha, Event, Config, Facts, ok(Grant)).

%% admit_reason(+Repo, +PR, +Sha, +Event, +Config, +Facts, -Decision) is semidet.
% Distinguishable refusals so the service can decide what to remember:
% refused(bot), refused(disabled), refused(not_triggered),
% refused(already_done), refused(lease_held) — only the last two keep the
% event unseen (retry/resume later); the others are final.
admit_reason(Repo, PR, Sha, Event, Config, Facts, ok(Grant)) :-
    spec_config_enabled(Config),
    spec_actor_not_bot(Event),
    spec_trigger_allowed(Event, Config),
    \+ member(posted_effect(Repo, PR, Sha), Facts),
    \+ member(lease(Repo, PR, _), Facts),
    route(Event, Route),
    Grant = grant{repo:Repo, pr:PR, sha:Sha,
                  event:Event, config:Config, route:Route}.
admit_reason(_Repo, _PR, _Sha, Event, _Config, _Facts, refused(bot)) :-
    \+ spec_actor_not_bot(Event).
admit_reason(_Repo, _PR, _Sha, _Event, Config, _Facts, refused(disabled)) :-
    \+ spec_config_enabled(Config).
admit_reason(_Repo, _PR, _Sha, _Event, _Config, _Facts, refused(not_triggered)) :-
    spec_config_enabled(Config),
    spec_actor_not_bot(Event),
    \+ spec_trigger_allowed(Event, Config).
admit_reason(Repo, PR, Sha, _Event, _Config, Facts, refused(already_done)) :-
    member(posted_effect(Repo, PR, Sha), Facts).
admit_reason(Repo, PR, _Sha, _Event, _Config, Facts, refused(lease_held)) :-
    \+ member(posted_effect(Repo, PR, _AnySha), Facts),
    member(lease(Repo, PR, _), Facts).

route(Event, task) :-
    spec_trigger(mention, Event).
route(Event, review) :-
    spec_trigger(command(review), Event).
route(Event, task) :-
    spec_trigger(command(ask), Event).
route(Event, review) :-
    spec_trigger(auto_review, Event).
