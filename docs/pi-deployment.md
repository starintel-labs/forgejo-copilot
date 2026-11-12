# Pi reviews and question deployment

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
Automatic polling is every 30 seconds. `auto: false` restricts runs to
`/review` or `@copilot review` comments by writers/admins. Only the latest
authorized manual request is acted on; historical requests are not queued.

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
It reserves $0.25 before each upstream attempt and never refunds failures or
small requests. This deliberately admits at most **20 model calls/day** (a
review can take several calls), so actual spend can be substantially below $5.
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
python3 -m unittest discover -s test -p test_pi_reviews.py -v
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
