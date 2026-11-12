# Repository contract

- Use test-driven development and the checks configured in `.copilot`.
- Make focused changes; do not replace real runtimes with imitation wrappers.
- Keep credentials, network effects and publication out of untrusted workers.
- Report actual test exits, not a model's assertion that work is verified.
- All AI changes go through a `copilot/` branch and human-reviewed PR.
- Never approve or merge an AI-generated PR automatically.
- `.copilot`, CI workflows and permission policy are human-owned boundaries.
