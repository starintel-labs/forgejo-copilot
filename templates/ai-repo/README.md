# AI-enabled repository

Mara and Star can answer questions, review PRs and implement authorized issue
requests in isolated Pi workspaces. AI work always comes back as a PR for human
review. The service never approves or merges its own changes.

## Start a task

Open an issue using the AI task template, or write:

```text
@mara /task Implement the requested feature and add tests.
```

Natural requests such as `@mara Bootstrap ...` and `@star Fix ...` also work.
Ask `@mara status`, `@mara cancel`, or `@mara retry` on that issue. A new
implementation request while a job is active revises its instructions; a
follow-up after a PR is ready updates the open task PR rather than merging it.
Use a normal question for explanation, or `@mara review` on a PR for a review.

## Policy and checks

`.copilot` on the base/default branch is the authority. A PR cannot enable
itself, expand allowed paths, alter the test command or change CI policy.
Only configured identities and repository writers can request implementation.
New repositories must be enrolled in the service watch list; historical PRs
are not automatically reviewed just because enrollment was added.

Run the same initial checks locally:

```sh
python3 -B -m unittest discover -s tests -v
```

Implementation workers have no credentials or general network. Checks run in
a separate network-none container. The gateway's $5/day UTC cap is shared
across all repositories, identities, reviews, questions and implementations.
No production deployment is implied by a generated PR.

Put implementation in `src/` or `actors/`, tests in `tests/`, and documentation
in `docs/`. Humans may deliberately update `.copilot` on the default branch to
change those boundaries. Never commit `.env`, API keys or runtime credentials.
