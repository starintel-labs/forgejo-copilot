# forgejo-copilot

## Deployed Pi review and question service

The deployable review path is now `scripts/pi_review_service.py`: a trusted
Forgejo poller launches **Pi 1.5.2 with read/bash tools in a disposable Docker
container**. It reviews code and answers repository questions using verified
real Forgejo accounts (`mara`, `star`), never display-name impersonation. It
posts comments but never pushes, approves, merges, or implements changes. The older Prolog task engine
below is not started by this deployment.

For every repository in the service watch list, merge this file as `.copilot`
into the target branch to enable reviews across all its PRs:

```yaml
enabled: true
auto: true
tasks: false
questions: true
question_mentions: mara,star
question_mode: explicit
question_context: issues,prs
question_access: writers
```

The controller reads configuration from the **base commit**, never from the PR
head. `enabled: false` (or a missing/malformed file) disables reviews.
`auto: false` allows manual `/review` or `@copilot review` comments from users
with write/admin permission. Each head/base/trigger combination is reviewed
once, including across restarts; changing either commit permits a fresh review.
Disablement or a changed head/base during a review suppresses the stale result.
With this configuration, questions mentioning `@mara` or `@star` must contain
`?` or `/ask`, and come from a repository writer/admin. Each account replies as
itself. Set `question_mode: mention` to answer any direct mention, restrict
`question_mentions` to one account, or use `questions: false` to disable replies.

See [Pi deployment and security](docs/pi-deployment.md) for installation,
repository enrollment, daily spending controls, limitations and verification.

## Original Prolog task engine

A long-running SWI-Prolog service that watches a Forgejo instance and acts as
**@copilot**: when a non-bot user mentions `@copilot` on an issue or PR, the
service executes the task on that issue — partition context, plan, branch,
implement, test, push, open a PR, and reply on the issue. `/review` and `/ask`
are secondary commands.

The model layer is [prolog-rlm](https://github.com/lost-rob0t/prolog-rlm)
(consumed as an external SWI-Prolog pack; this repository owns no runtime
code). Prolog owns task state, idempotency, scheduling, and authority. The
language model chooses semantic strategy.

## Design

- **Polling only.** The service holds no inbound network surface; it polls the
  configured Forgejo REST API with an `updated_since` cursor.
- **Opt-in per repository.** A `.copilot` file at the **PR base branch HEAD**
  enables the bot. A `.copilot` added inside a PR branch never self-enables.
  Explicit `enabled: false` opts out.
- **Idempotency.** One admitted run per `(repo, pr, sha)` recorded in a durable
  effect ledger; a force-pushed new sha re-admits. One lease per `(repo, pr)`
  with fencing.
- **Execution graph.** `rlm_graph` state machine with durable checkpoints;
  restarts resume from the last checkpoint without duplicate posts.
- **Authority.** Pushes only to branches under `copilot/`; protected branches
  (`main`, …) are never pushed. The bot never approves or merges its own PRs
  (the human gate stays human). No shell/process capability exists in any tool.
  Network authority is scoped to the configured Forgejo API, model-provider,
  fallback-model, and Brave-search endpoints only.
- **Model downgrade chain.** Primary model → alternate model → fallback LLM
  endpoint (env-configured) → a visible failure comment on the issue. Never a
  silent failure. Provider and model per run are recorded in the effect ledger
  for spend tracing.

## Configuration (environment only)

| Variable | Purpose |
| --- | --- |
| `FORGEJO_URL` | Base URL of the Forgejo API (e.g. `https://git.example.com/api/v1`) |
| `FORGEJO_TOKEN` | Forgejo access token for the bot account |
| `OPENROUTER_API_KEY` | OpenRouter credential for the model tiers |
| `FALLBACK_LLM_URL` | OpenAI-compatible fallback endpoint URL |
| `FALLBACK_LLM_KEY` | Credential for the fallback endpoint |
| `BRAVE_API_KEY` | Brave Search API key (web research tools) |
| `COPILOT_STATE_DIR` | Durable state directory (ledger, checkpoints, cursor). Default `./state/run` |
| `COPILOT_POLL_SECONDS` | Poll interval. Default `30` |
| `COPILOT_REPOS` | Comma-separated `owner/name` watch list |

Secrets are read from the environment at request time and never logged.

## `.copilot` file

YAML-ish key/value file at the base branch head:

```
enabled: true
model: fast        # fast | strong
auto: true         # auto-review of opened PRs
tasks: true        # execute @copilot task mentions
```

Defaults: `model=fast`, `auto=true`, `tasks=true`; absent file → disabled.

## Commands

- `@copilot <task>` — execute the task on this issue/PR.
- `/review` — review the current PR diff.
- `/ask <question>` — answer grounded in the issue context.

## Running the service

```sh
FORGEJO_URL=https://git.example.com/api/v1 \
FORGEJO_TOKEN=... \
  swipl -s bin/copilot-service.pl -- \
    --forever \
    --repo owner/name \
    [--repo other/repo] \
    [--state-dir state/run] \
    [--poll-seconds 30] \
    [--config-branch Branch] \
    [--model-step Module:Pred4]
```

- The daemon **fails fast** when `FORGEJO_URL`/`FORGEJO_TOKEN` are missing
  or empty, or when no `--repo` is given (exit 1 with a message).
- On start it **resumes paused runs** from the durable checkpoints in
  `--state-dir` before polling, so a crashed run finishes exactly once.
- Every poll cycle is wrapped in catch-and-continue: one bad cycle logs
  an error and the loop keeps going.
- `--once` resumes, polls once, and exits 0 (cron/CI friendly).
- `--help` prints usage; unknown flags exit 2.

**Working on any branch.** PR events read `.copilot` from the PR base
branch HEAD (any branch can be a merge target). For issue events (no
PR), `.copilot` is read from `--config-branch` (default: the repo's
default branch), and task runs branch from that same branch — so the
bot can operate on a feature branch before anything is merged:

```sh
FORGEJO_URL=... FORGEJO_TOKEN=... \
  swipl -s bin/copilot-service.pl -- --forever --repo nsaspy/forgejo-copilot \
    --config-branch handoff/dogfood-plan
```

### Smoke (credential-free)

```sh
nix develop
swipl -q -s bin/copilot-demo.pl   # one mention through the pipeline, no env, no network
```

### Self-hosting

The root `.copilot` now enables automatic reviews and disables implementation
tasks. Use the Pi deployment above for reviews. Running implementation tasks
with the original engine requires a deliberate `tasks: true` opt-in; it is not
part of the deployed review service.

## Running tests

```sh
nix develop
swipl -q -s test/run_tests.pl   # PlUnit suite (deterministic)
swipl -q -s verify/verify.pl    # formal-spec conformance gate
```

## Repository layout

```
spec/   formal Prolog specification (invariants as facts/rules)
packs/  prolog-rlm tool packs (forgejo API, web research)
src/    service, config, admission gate, graph, model strategy
test/   PlUnit suite + fresh-process fixtures
verify/ spec-vs-implementation conformance script
state/  durable run state (gitignored), build/task knowledge base
```
