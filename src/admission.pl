:- module(admission,
          [ admit/7
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
    spec_config_enabled(Config),
    spec_actor_not_bot(Event),
    spec_trigger_allowed(Event, Config),
    \+ member(posted_effect(Repo, PR, Sha), Facts),
    \+ member(lease(Repo, PR, _), Facts),
    route(Event, Route),
    Grant = grant{repo:Repo, pr:PR, sha:Sha,
                  event:Event, config:Config, route:Route}.

route(Event, task) :-
    spec_trigger(mention, Event).
route(Event, review) :-
    spec_trigger(command(review), Event).
route(Event, task) :-
    spec_trigger(command(ask), Event).
route(Event, review) :-
    spec_trigger(auto_review, Event).
