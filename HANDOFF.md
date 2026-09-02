# HANDOFF — forgejo-copilot build state

Written at hand-off from a coding session that ran out of context. Read
this before touching `test/07_service_restart.pl.known-red` or the resume
path in `src/service.pl`.

## How to work here

- Task/deps/evidence KB: `state/tasks.pl` via `scripts/kb.pl` (see file
  header). Set `KB_SESSION=<your name>` in the environment.
- Test gate: `PROLOG_RLM_HOME=<prolog-rlm checkout> swipl -s test/run_tests.pl`
  or `nix develop` (SWIPL_PACK_PATH has the prolog-rlm pack).
- Focused run: `swipl -q -s test/run_one.pl -- 04_graph.pl`
- TDD: add/extend the numbered test file first, then make it green.
- Commit style: imperative, prefix `copilot: ...`.

## What is DONE and verified (gate green: 95/95, commit c3072f2)

- `spec/forgejo_copilot_spec.pl` — formal Prolog spec of every invariant:
  abstract graph machine (done terminal, failed absorbent, task+review
  chains), .copilot config semantics, admission gate, authority (copilot/*
  namespace, protected branches, never-approve-own-PR, closed network
  scope, no shell/process), tool inventory with ceilings, model tiers +
  downgrade chain. The 30-case battery was verified in a live Prolog MCP
  session AND is mirrored in `test/01_spec.pl` (29 tests).
- `src/copilot_config.pl` — fail-closed .copilot parser (10 tests).
- `src/admission.pl` + `src/forgejo_event.pl` + `src/journal.pl` — pure
  admission gate with distinguishable refusals, event classification,
  durable journal over `rlm_effect_persist` (leases w/ run identity +
  append-only lease index, posted-effect records, seen-ids, cursor, spend
  records). 21 tests.
- `src/copilot_graph.pl` — rlm_graph realization: abstract terminals
  done/failed map to structural `end` + `state.status`; delegate protocol
  ok/failed/interrupt with grounded failure patches. 8 tests.
- `src/model_strategy.pl` — tier selection, env-built provider chain,
  downgrade on 401/429/5xx/egress, spend ledger records. 12 tests.
- `packs/forgejo.pl`, `packs/web.pl` — tool packs; schemas/ceilings match
  spec; capability-denial and schema-rejection tests; SSRF-guarded
  web_fetch; host-side `get_file_content/5` (.copilot reads). 15 tests.
- `src/copilot_delegate.pl` — real delegate (fetch/plan/branch/implement/
  self-verify/push/pr/reply with citation check). NOT yet unit-tested.
- `src/service.pl` — pipeline: poll → classify → admit → lease → graph
  run (persist checkpoints) → effect record + lease release → visible
  failure comment on chain exhaustion; `resume_paused/1` for fresh-process
  resumption.
- flake.nix: devShell (swipl + prolog-rlm pack) and checks (spec-verify,
  unit-tests). verify/verify.pl is STILL A TODO (see KB).

## The ONE known-red: test/07_service_restart.pl.known-red

Renamed to `.known-red` so the gate passes; restore the name to work on it.
It contains the intended contract (already written). Symptom:

- In fresh `swipl -s test/scripts/service_worker.pl -- phase2 <dir>`
  processes, `service:resume_paused/1` either fails silently or the
  process hangs in `halt/1` (lingering rlm_async worker threads — prolog-rlm
  exports no scheduler shutdown; prolog-rlm's own restart fixtures use
  wait-with-timeout + `process_kill`, which the fixture already does).
- Strongest evidence: an in-process replica of the exact resume steps
  (`/tmp/opencode/dbgw21.pl` pattern: open persist backend →
  graph_checkpoint → patch data → graph_resume → finalize) COMPLETED fine
  while `service:resume_one/2` in the same scenario died between backend
  open and the checkpoint read. Treat the module-boundary (module-qualified
  goals, partial application, operator forms) as the suspect.
- Another observed point: worker phase2 saw `journal:lease_runs` return
  zero while a direct process saw the lease — recheck `service:init/1`
  (attach semantics of `rlm_effect_persist_open` on an existing journal
  with a stale `.lock` sidecar) before blaming the query.
- Suggested next step: reproduce with a MINIMAL fresh process (not the
  full worker): open journal, open persist graph backend, call
  `service:resume_one/2` only, with file-based logging (stderr is
  buffered/lost on kill — use `dbg_log`-style append logging).

## Repo hygiene for publish

- grep the tree for private infra before publishing: endpoints/hosts/ports
  must only ever come from env (FORGEJO_URL, FORGEJO_TOKEN,
  OPENROUTER_API_KEY, FALLBACK_LLM_URL/KEY/MODEL, BRAVE_API_KEY,
  COPILOT_*). Nothing is hardcoded; keep it that way.

## Open work after the fix (see state/tasks.pl)

- t_restart: get 07 green, un-park it, wire into CI checks.
- t_verify: `verify/verify.pl` — spec-vs-implementation conformance gate
  (graph edges vs spec_transition, tool registry vs spec_tool, authority
  absolutes).
- t_smoke: credential-free smoke (`swipl -s src/service.pl -- demo`-style)
  mirroring prolog-rlm's CLI demo pattern.
- Delegate unit tests (planned/implemented paths with a fake api hook).
