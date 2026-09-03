# HANDOFF — forgejo-copilot, dogfood build-out complete (main path)

Written at the end of the dogfood session. Every claim is backed by a
live run recorded in `.prolog/facts.kb` or a KB evidence line — nothing
is carried over.

## How to work here

- prolog-rlm runtime: `PROLOG_RLM_HOME=~/Documents/Projects/prolog-rlm`
  (checkout, latest main — do NOT use `~/ChatGPT/prolog-rlm`, it is an
  empty repo). `swipl -q -s test/run_tests.pl` is the full gate.
- Focused run: `swipl -q -s test/run_one.pl -- <file>.pl`
- Conformance gate: `swipl -q -s verify/verify.pl` (exit 1 on drift).
- Smoke: `swipl -q -s bin/copilot-demo.pl` (exit 0, credential-free).
- Daemon smoke: `swipl -q -s bin/copilot-service.pl -- --help` (exit 0);
  without env it fails fast (exit 1).
- Everything wired as flake checks: `nix flake check` (all green;
  `SWIPL_PACK_PATH` is set by the checks; `flake.lock` is committed).
- Task/deps KB: `state/tasks.pl` via `scripts/kb.pl`
  (`KB_SESSION=<name>`). Commit KB changes.
- Commit style: imperative, prefix `copilot: ...`. TDD; deterministic
  tests only (no sleeps; wait-timeout+kill for subprocess fixtures).

## DONE this session (handoff/dogfood-plan @ 966bd0c)

- t_delegate (ac56c0f): 08 un-parked and green 18/18; full gate 115/115.
  - Reusable decode layer (PORTABLE back to prolog-rlm):
    `src/llm_text.pl` — `strip_code_fences/2` (whole-text fence with
    optional tag; inner content byte-exact), `structured_from_text/3`
    (fence strip -> `rlm_chain` closed-schema decode+validate; rejection
    is FAILURE, never an exception), `nonempty_text/1` (string-correct
    empty check — beware `Str \== ''` vs string `""`).
    `src/plan_items.pl` — the "expert" template: text -> fence strip ->
    closed schema -> authority checks (non-empty, cap 16, safe relative
    path) -> normalized `change{path,change,message}` atoms.
    `src/repo_ref.pl` — shared Owner/Name parser (was 3 copies).
  - `copilot_delegate:model_call` reads the trusted `model_step` Pred4
    from run data (same shape as `model_strategy` step_call), threads
    `run:<repo>:<pr>:<sha>` so spend lands in the journal (proven by
    test: `rlm_effect_persist:effect_call_record(..., spend-RunId, ...)`).
    Config comes from `State.data.grant.config` (the grant carries the
    effective .copilot config). With no hook in data it uses the real
    HTTP tier chain.
  - `plan_task` FAILS (never throws) on invalid/empty/over-cap/
    unexpected-field/unsafe-path plans; `copilot_graph:node_step` routes
    a failing delegate clause to the failed terminal, so rejection still
    ends in the visible failure comment.
  - `content_for`: fetches the ORIGINAL file from the base branch via
    the api hook, rewrites via model, strips fences, requires
    non-empty, pushes base64.
  - `service`: `base_branch` is ALWAYS in run data (PR base else
    default branch); `model_step(Pred4)` service option is injected into
    run data and re-injected on fresh-process resume (alongside
    delegate/api).
- t_daemon (966bd0c): `src/copilot_daemon.pl` +
  `bin/copilot-service.pl`. CLI: `--once|--forever` (last wins),
  repeatable `--repo`, `--state-dir`, `--poll-seconds`, `--model-step`
  term, `--help`. Fail-fast env gate (`FORGEJO_URL`/`FORGEJO_TOKEN`
  non-empty, >= 1 repo) — proven: missing env exits 1 with a message.
  `resume_paused` on start; per-cycle catch-and-continue loop. Tests
  drive `cli_options`/`env_options` directly (deterministic; 09: 13/13).
- t_selfhost (966bd0c): `.copilot` committed at repo root
  (enabled:true, tasks:true, auto:false, model:fast) + README dogfood
  runbook. `09_daemon.pl` asserts the file parses into exactly that
  config.
- Gate at HEAD: 128/128; verify 18/18; demo exit 0; `nix flake check`
  all green.

## SWI-Prolog gotchas that cost time this session (do not re-derive)

- Dict unification requires the SAME key set:
  `_{path:P} = _{owner:O,repo:R,branch:B,path:P}` FAILS. Fake api hooks
  must either bind args with a variable or repeat the full key set.
  Same for response patterns: use `get_dict/3` against
  `ok(response{...})` instead of subset dict patterns.
- `Str \== ''` compares against the empty ATOM; a string `""` is never
  equal to it. Compare against `""`.
- `atomic_list_concat/3` over string elements returns a STRING; over
  atom elements an ATOM. Normalize with a text_string helper, not a
  one-directional `atom_string/2`.
- `journal:with_test_journal(Goal)` calls the goal in module `journal`:
  qualify test bodies with `user:` at the call site and keep them at
  file level. Same for closures handed through run data (`api`,
  `model_step`): the delegate module only sees them as
  `user:fake_api/3`.
- plunit file-level predicates written INSIDE begin_tests blocks land
  in the plunit module — hoist shared fixtures to file level.
- Passing a PREDICATE NAME where a term is expected silently fails:
  call `test_grant(Grant)` / `plan_schema(Spec)` first, then pass the
  value.

## What "ready" looks like now (dogfood)

1. Point the daemon at its own repo:
   `FORGEJO_URL=... FORGEJO_TOKEN=... swipl -s bin/copilot-service.pl -- --forever --repo nsaspy/forgejo-copilot`
2. Open an issue mentioning @copilot with a small task; the bot branches
   under `copilot/`, pushes, opens a PR; `nix flake check` gates the
   merge; the human approves (never the bot).
3. Watch the journal under `state/run/` (leases, effects, spend).

## Next steps (not started)

- t_dogfood-live: actually run the loop above once and record the run
  id + evidence in the KB.
- Push `handoff/dogfood-plan` and open a PR against main so the selfhost
  loop exercises the flake checks.
- Port `llm_text.pl` (+ the plan_items expert shape) upstream to
  prolog-rlm as the structured-output bridge; keep this repo's copies
  in sync until upstream adopts them.
- Consider the review/ask flows end-to-end with a live model (auto is
  off on purpose; use /review manually).

## Repo hygiene

- All credentials/endpoints via env only (FORGEJO_URL, FORGEJO_TOKEN,
  OPENROUTER_API_KEY, FALLBACK_*, BRAVE_API_KEY, COPILOT_*). The only
  literal URLs are public placeholders (git.example.com, the public
  Brave API constant, loopback test dummies).
- `origin` is SSH (`ssh://forgejo@git.starintel.actor:22/nsaspy/
  forgejo-copilot.git`); HTTPS has no credential helper here.
