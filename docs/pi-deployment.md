# Pi reviews, questions and background tasks

## Install / update

Requirements: Linux, Docker supporting internal bridges with
`gateway_mode_ipv4=isolated`, host UID 1000, Python 3, systemd user services,
and an existing Forgejo token with repository read and issue-comment rights.
The trusted controller needs Docker access; the agent must never receive it.

```sh
python3 scripts/deploy_pi_reviews.py \
  --repo owner/project \
  --repo owner/other-project \
  --token-file /absolute/path/to/forgejo-token \
  --identity mara=/absolute/path/to/mara-token \
  --identity star=/absolute/path/to/star-token \
  --review-as mara
```

Pass the **complete** watch list on each deployment. Enrollment is an explicit
operator allowlist, not discovery of every repository the account can access.
Then merge `.copilot` with `enabled: true`, `auto: true`, `tasks: false` into
each target branch. This one file enables reviews for every PR against that
branch, including new commits on existing PRs. A PR cannot self-enable.
Automatic polling is every 30 seconds. Explicit `/review`, `@mara review`,
`@star review` or legacy `@copilot review` comments by writers/admins work
regardless of `auto`. Only the latest
authorized manual request is acted on; historical requests are not queued.
New enrollment records a persistent automatic-review cutoff: old PRs need an
explicit request, avoiding a bulk historical review storm.

Repository-owned templates and scripts are the durable deployment source.
Runtime copies go to `~/.local/share/forgejo-copilot/`; private configuration
to `~/.config/forgejo-copilot/service.json`; SQLite state and budget to
`~/.local/state/forgejo-copilot/`. Do not edit generated copies.
The installer refuses to overwrite a service unit symlink owned by another
configuration manager. It stops the controller during gateway replacement.

```sh
systemctl --user status forgejo-copilot.service
journalctl --user -u forgejo-copilot.service
systemctl --user stop forgejo-copilot.service
# To also stop model access:
docker stop forgejo-copilot-gateway
```

The gateway has Docker's `unless-stopped` restart policy. The controller is
enabled under the user's default target; starting before login requires the
machine's existing systemd linger policy. Review/approval remains a human gate.

## When to answer questions

The same controller serves independent **real account identities**, not
aliases attached to the owner's account. Every configured token is checked
against `GET /user` at startup; a mismatch fails closed. `--review-as mara`
also makes review comments originate from Mara. The coordinator's owner token
is retained host-side for repository admission and collaborator-permission
lookups; read-only collaborators cannot perform those permission lookups.

Add these settings to `.copilot` on the base/default branch:

```yaml
questions: true
question_mentions: mara,star
question_mode: explicit
question_context: issues,prs
question_access: writers
```

| Setting | Behavior |
| --- | --- |
| `questions: false` | Disable question replies independently of automatic reviews (default). |
| `question_mentions: mara` | Only Mara responds; use `mara,star` for both. Unconfigured identities never impersonate another account. |
| `question_mode: explicit` | A direct mention plus `?` or `/ask` is required. |
| `question_mode: mention` | Any direct mention of a configured identity triggers an answer (default mode). |
| `question_context: issues` | Reply only on issues; `prs` only on PRs; `issues,prs` on both (default). |
| `question_access: writers` | Only writers/admins may invoke questions (default). `anyone` permits other readers to invoke, within the same shared budget. |

Mentions are case-insensitive whole handles, not email fragments or prefixes.
Quoted lines and fenced code do not trigger answers. Messages by configured
responders and bot-marked users are ignored to prevent reply loops. Questions
in issue bodies and comments on open issues/PRs are supported; historical
unanswered mentions in open threads can be picked up when enabled. Thread
context is bounded; source inspection uses the issue's default-branch snapshot
or PR head plus diff. No implementation or write tools are granted.

Each identity answers a given message revision once, even after restart or a
default-branch update. Editing the question allows a new answer. Policy,
question text, open state and snapshot freshness are checked again before
posting; disabling a responder suppresses its in-flight answer. Both accounts
share the same gateway and $5 daily cap; enabling Star does not double it.

An administrator can mint narrowly scoped tokens for existing accounts without
resetting their passwords or creating look-alike users:

```sh
python3 scripts/mint_forgejo_identities.py \
  --host root@10.60.60.11 --jump proxmox --user mara --user star
```

The helper resolves the deployed Forgejo CLI from systemd, uses
`read:repository,write:issue,read:user`, writes mode-0600 secret files and
verifies account ownership. Existing files are reused, not silently rotated.
The deployment uses the already-existing `mara` and `star` accounts. Star is
an existing administrator account: its token excludes admin scopes, but its
account itself is not demoted or otherwise changed.

## Credentials and spending

The installer uses `~/.config/openrouter/management-key` **only on the host**
to create a separate `forgejo-copilot-key`. Existing farm/research keys are
not modified. The child key is reused on subsequent deployments, and must
verify as `limit=5`, `limit_reset=daily`, `include_byok_in_limit=true`.
OpenRouter resets daily limits at **00:00 UTC**. This is a maximum, not a
minimum purchase or daily scheduled spend.

Only the gateway receives the child key, via a read-only secret mount. The
agent receives neither OpenRouter nor Forgejo credentials. The host token is
read from a private file. New review comments are posted as `mara`; answers
are posted as the real mentioned `mara`/`star` user. The earliest review fixture
was posted as `nsaspy` before real identities were requested and provisioned.

The gateway independently enforces a **conservative local $5 UTC daily
reservation budget**, shared across every repository, persisted in SQLite.
It reserves $0.25 before each upstream attempt. A complete provider SSE stream
with validated token usage releases the excess reservation; charges use the
admitted price ceilings, rounded up to whole cents (minimum one cent).
Failures, partial streams and missing/invalid usage retain the full reservation.
Live provider daily spend is also a floor for local admission. There is no fixed
20-call limit after settlement; a review/task can take several calls.
Never delete the budget database to work around exhaustion.

The only admitted model is `openai/gpt-4.1-mini`: at most 200KB of text request
data and 4096 output tokens. Before each attempt the gateway checks the live
key limit and model catalog; input prices above $1/M, output prices above $4/M
or extra unconditional request/reasoning fees fail closed. Optional paid
search/image products are mechanically disabled, not invoked. These limits make each
$0.25 reservation conservative. No server-side web tools, images, alternative
models, arbitrary endpoints, or client-supplied provider overrides are allowed.
Provider-side daily enforcement remains an additional independent boundary.

## Container boundary

- Each review or question gets a fresh non-root container with a read-only root and
  repository snapshot, writable 256MB `/tmp`, one CPU, 1GB RAM, 128 PIDs,
  default Docker seccomp, all capabilities dropped and no-new-privileges.
- No host home, credential files, SSH agent, Docker socket, or host network.
- The sole agent network is an internal, **host-isolated** bridge. Only the
  model gateway is attached alongside it. The gateway also has an external
  bridge for OpenRouter HTTPS; it is not a general HTTP/CONNECT proxy and
  exposes no published host ports.
- Pi runs without extensions, MCP, project settings, AGENTS/CLAUDE context
  discovery, skills, prompt templates, themes, telemetry or startup updates.
  Repository content remains untrusted input; prompt injection is not solved
  by a prompt. Credentials and write authority are removed mechanically.
- Archives reject path traversal and oversized contents; symlinks and `.pi`,
  `.git`, `.env`, `.envrc` entries are omitted. Dependencies are not installed
  from untrusted packages. Bounded Python/local checks can run via bash.
- Execution times out after four minutes. Output is bounded to 8MB and
   discarded after parsing; raw prompts and model output are not journaled.
- Graceful termination removes the worker. Startup removes any labeled
  orphan workers left by a controller crash. Failures get one visible notice
  and an hour's retry backoff; restart does not erase the budget or ledger.

Docker shares the host kernel: this is not a VM or a promise of resistance
to kernel exploits. Do not add privileged mode, host mounts or general egress.

## Verification

```sh
python3 -B -m unittest discover -s test -p 'test_*.py' -v
COPILOT_DOCKER_TESTS=1 python3 -B -m unittest discover -s test -p test_worker_docker.py -v
python3 scripts/check_pi_deployment.py --repo nsaspy/forgejo-copilot-pi-test --pr 1 --question-issue 2 --exercise-restart
```

The live verifier checks systemd, gateway isolation, direct network denial,
read-only mounts, missing credentials/socket, gateway model policy, the
provider-side daily cap, and one real review per head/base pair detecting the intentional
`calculator.py` empty-input regression with observed `read` tool execution.
It also checks one source-grounded answer from each real account on issue #2,
and a fresh one-shot poll across a service restart without duplicate replies.
The private fixture issue/PR must remain open and unmerged for repeat verification.

External references: [Pi CLI](https://pi.dev/),
[OpenRouter key creation](https://openrouter.ai/docs/api/api-reference/api-keys/create-keys),
[OpenRouter limits](https://openrouter.ai/docs/api_reference/limits).

## Background implementation

`templates/ai-repo/` is the AI-enabled repository scaffold. The provisioning
helper creates a new Forgejo template and can seed an explicitly named **empty**
repository; it refuses to overwrite a non-empty repository. Human-owned `main`
protection requires one approval and `copilot/tests`; bots are not on its push
whitelist. Enroll generated repositories separately in the complete watch list.

On the default branch, opt in with:

```yaml
tasks: true
task_mentions: mara,star
task_tests: python3 -B -m unittest discover -s tests -v
task_allowed_paths: src/,tests/,docs/,actors/,README.md,pyproject.toml
```

Mint separate host-only publisher tokens using `mint_forgejo_identities.py
--task-writer` (repository/issue write and user read), then add one or more
`--task-identity mara=/absolute/path/to/mara-task-token` flags to deployment.
These are distinct from the read/comment tokens. The trusted publisher needs
repository write access; no Forgejo token enters an agent/check container.
The installer enables `forgejo-copilot-worker.service` when task writers exist.

On an open issue, writers may use `@mara /task <request>`, natural requests such
as `@star Fix ...`, and `@mara status`, `cancel` or `retry`. Follow-up task
instructions revise the same active job. After a ready result, a new task can
continue its open PR. SQLite retains task revisions, check exit/output, artifact
hash, publication phase and delivery markers across restart. Retry increments
the revision so a second failure/result gets its own notice.

The implementation container gets read-only `/input` and a 128MB tmpfs
`/workspace`, never a writable host checkout. Each implementation attempt has
a ten-minute limit; one repair attempt follows failed checks. Captured partial
work is validated against allowed paths before retention/reuse on interruption.
Checks run independently against the exported read-only snapshot, with no
network and a three-minute limit. Publication rechecks permission, open issue
and default-branch policy, validates the whole resulting commit against the
tested artifact, writes only a `copilot/` branch and opens a PR. It never
approves, merges or deploys. Passing configured tests is not proof that every
natural-language acceptance criterion is met; human code review remains required.

Optional `--task-reference owner/repo=/absolute/pinned/export` mounts immutable
source at `/reference` and sets `STARLANG_HOME=/reference`. Use
`scripts/export_task_reference.py` to export selected regular files from an exact
Git commit without exposing a dirty working checkout. Dependencies must already
be available; the worker image includes SBCL but does not install task packages.

Inspect both service journals. Stop **both** controller and worker before
maintenance. Do not redeploy while work is active unless interruption is intended.
`scripts/check_implementation.py --repo owner/repo --issue 1 --rerun-checks`
checks real PR/status/artifact evidence and independently reruns configured checks.
`--wait 900 --after <Unix timestamp>` waits on state-directory events and ignores
old terminal states. This does not replace review of the generated code.

## Optional Discord transport (not activated)

Activation is deferred to [infra #259](https://git.starintel.actor/starintel-labs/starintel-infra/issues/259).
No valid bot credential or approved channel/user bindings have been verified.
SDK/unit tests do not establish a live Discord deployment.

Install `requirements-discord.txt` in a dedicated environment and copy
`deploy/discord.json.example` to private configuration. Supply a bot token (not
a personal account credential), the matching application ID and explicit bindings:

```json
"channels": {
  "CHANNEL_ID": {
    "guild_id": "GUILD_ID",
    "repo": "owner/repo",
    "mode": "mention",
    "users": {"DISCORD_USER_ID": "forgejo_writer_login"}
  }
}
```

Set `enabled: true` only after consent and start
`python3 scripts/copilot_discord.py --config /absolute/private/discord.json`.
This adapter is not started by the review installer. It needs guild/channel
visibility, message sending, embeds and history access; invite with bot and
application-command scopes. Enable the message-content intent in the portal and
configuration only for approved natural-message use. Slash commands do not need
that privileged intent. `mode: all` additionally requires message-content opt-in.

`/copilot` supports ask/task/status/cancel/retry/forget and Mara/Star selection.
Mentions/replies to the bot use the same router; prefix `star` to select Star.
DMs, other guilds, unbound channels and unmapped users are denied. Threads inherit
their parent binding. Every request rechecks the mapped account's Forgejo write
permission and default-branch policy. Conversation history is bounded to twelve
entries, isolated by repository/guild/channel/user/persona; `forget` clears that
scope, not task evidence. Replies are visible to channel readers, **not private**
to the invoking user. Task evidence includes a Discord source link.

Reply caching and per-part markers reduce duplicates but cannot guarantee
exactly-once delivery across remote API failures. The adapter registers only its
`copilot` command, not a bulk sync that removes other application commands.
Its read-only chat containers have a separate label so controller orphan cleanup
does not terminate them. The same gateway and $5/day cap cover all transports.
