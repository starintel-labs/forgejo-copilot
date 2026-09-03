# HANDOFF — forgejo-copilot, dogfood build-out (in flight)

Written fresh at the end of the resume-fix/verification session. Every
claim below is backed by a live run or a KB evidence line — nothing is
carried over from the previous (deleted) hand-off.

## How to work here

- prolog-rlm runtime: `PROLOG_RLM_HOME=~/Documents/Projects/prolog-rlm`
  (checkout, latest main — do NOT use `~/ChatGPT/prolog-rlm`, it is an
  empty repo). `swipl -q -s test/run_tests.pl` is the full gate.
- Focused run: `swipl -q -s test/run_one.pl -- <file>.pl`
- Conformance gate: `swipl -q -s verify/verify.pl` (exit 1 on drift).
- Smoke: `swipl -q -s bin/copilot-demo.pl` (exit 0, credential-free).
- Everything wired as flake checks: `nix flake check` (3/3 green;
  `SWIPL_PACK_PATH` is set by the checks; `flake.lock` is committed).
- Task/deps KB: `state/tasks.pl` via `scripts/kb.pl`
  (`KB_SESSION=<name>`). Commit KB changes.
- Commit style: imperative, prefix `copilot: ...`. TDD; deterministic
  tests only (no sleeps; wait-timeout+kill for subprocess fixtures).

## DONE and verified (main @ 27b3dff, pushed)

- Fresh-process resume fixed (e413c53): `resume_one/2` delivers the
  fresh-process `delegate`/`api` through the resume patch
  (`resume(resumed, patch{data: ...})`) — `graph_resume` reloads state
  from the durable checkpoint and ignores locally patched state. Lease
  kept on re-pause, released on refusal/missing checkpoint. Gate 96/96.
- Conformance gate `verify/verify.pl` (db4efbe): 18 checks — graph vs
  `spec_transition` (end+status mapping), failure routes, end absorbing,
  tool schemas vs `spec_tool/4` (names/effects/ceilings, no
  shell/process/arbitrary-network capability), authority absolutes,
  model tiers + downgrade chain. It caught and fixed a real drift:
  `tier_chain` tried `fallback_endpoint` FIRST; spec order is
  primary -> alternate -> fallback -> visible failure.
- Smoke (d8ea39c): `bin/copilot-demo.pl` + `bin/demo_delegate.pl` drive
  one mention through admit -> graph -> done with fake api; re-poll is
  refused (already_done). No env, no network.
- KB: t_restart, t_verify, t_smoke all `done` with evidence lines.

## The one parked red: test/08_delegate.pl.known-red (t_delegate)

In-flight TDD start for the REAL delegate (`src/copilot_delegate.pl`).
Status: 5/12 green when run standalone. Remaining failures share one
fixture bug and then need implementation work:

1. Fixture bug (do first): `journal:with_test_journal(reply_body)`
   resolves the goal in module `journal` because the body predicates
   were defined inside plunit blocks. Fix by hoisting the body
   predicates to file level (user context) or qualifying the goal with
   the current module at the call site.
2. Then implement, in this order (all completion-mode / symbolic):
   - `copilot_delegate:model_call` must read the trusted model step
     hook from `State.data.model_step` (Pred4, same shape as
     `model_strategy` `step_call`) and thread
     `run_id(run:<repo>:<pr>:<sha>)` so spend records land
     (`spec_ledger_records_spend`). Config comes from
     `State.data.grant.config` — the grant already carries the
     effective .copilot config.
   - `plan_task`/`parse_plan_items`: replace the `parse_plan_items(
     _Text, []).` stub with real structured decoding:
     `rlm_chain:structured_schema_compile(list(object([field(path,
     string, required), field(change, string, required), field(message,
     string, required)])), ok(Schema))` then
     `structured_decode_validate(Schema, Stripped, ok(Plan))` after
     stripping markdown fences host-side. Enforce `Plan \== []`,
     `length(Plan) =< 16`, and safe relative paths (no leading `/`, no
     `..`). Rejecting is correct behavior: it routes to the failed
     terminal -> visible failure comment.
   - `content_for`: fetch the ORIGINAL file from the base branch via
     the api hook (`get_file_content`, args `{owner, repo, branch,
     path}`), call the model for the full new content, strip fences,
     require non-empty, `base64_encoded/3`, push. Needs
     `data.base_branch` to ALWAYS be present — see next point.
   - `service:run_task/2` must put `base_branch` into the run data
     unconditionally (PR base branch when a PR exists, else
     `default_branch/1`), and accept a new service option
     `model_step(Pred4)` into the data dict. `resume_one/2` must
     re-inject `model_step` the same way it re-injects `api`.
   - `reply_with_citations` and `post_review` (request_changes only)
     already conform; tests cover them once the fixture is fixed.

## Dogfood blockers (what "ready" means)

1. t_delegate (above) — every real task currently dies at `replied`
   because the plan parser is a stub, and pushes placeholder content.
2. t_daemon — there is NO daemon entry point. `service.pl` exports
   `poll_once/1` only; the documented `run_forever` does not exist.
   Build `bin/copilot-service.pl`: `--once` / `--forever`, env
   fail-fast (FORGEJO_URL/TOKEN), `resume_paused/1` on start, catch +
   continue poll loop with `poll_seconds` (sleep is fine there; tests
   stay deterministic).
3. t_selfhost — commit a `.copilot` to THIS repo (enabled:true,
   tasks:true, auto:false to avoid review storms) + README runbook, so
   the bot can be pointed at its own repo and its PRs come back through
   the flake checks. That closes the dogfood loop.

## Architecture notes (so the next session doesn't re-derive)

- Completion mode is the paradigm: the model is a text->text oracle;
  all agency is Prolog (graph machine + delegate). No native tool
  calls; `rlm_direct` (provider-native tool loop) exists upstream but
  would need a spec amendment (model holds no execution capability).
- Node patches must only touch schema fields; run payload goes through
  the `data` field (`patch{data: Data.put(Key, Value)}`).
- `graph_resume` reloads state from the checkpoint — anything a fresh
  process must supply (delegate/api/model_step) goes through the
  resume patch.
- Journal enumeration uses append-only indexes (lease-index,
  effect-index); `key/3` formatting cannot enumerate with unbound
  args. `journal:facts/1` returns `posted_effect/3` + `lease/3`.
- `read_line_to_string` returns `end_of_file` at EOF (a success).
- Delegate protocol outcomes: `ok(Patch) | failed(Error) |
  interrupt(R, P)`; a throw becomes a failed terminal, never a retry.

## Repo hygiene

- All credentials/endpoints via env only (FORGEJO_URL, FORGEJO_TOKEN,
  OPENROUTER_API_KEY, FALLBACK_*, BRAVE_API_KEY, COPILOT_*). The only
  literal URLs are public placeholders (git.example.com, the public
  Brave API constant, loopback test dummies).
- `origin` is SSH (`ssh://forgejo@git.starintel.actor:22/nsaspy/
  forgejo-copilot.git`); HTTPS has no credential helper here.
