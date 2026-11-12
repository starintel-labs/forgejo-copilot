#!/bin/sh
set -eu
mkdir -p "$PI_CODING_AGENT_DIR"
cp /opt/copilot/models.json "$PI_CODING_AGENT_DIR/models.json"
exec pi --print --mode json --no-session --no-extensions --no-skills --no-prompt-templates \
    --no-context-files --no-mcp --no-themes --no-approve --offline \
    --provider copilot --model openai/gpt-4.1-mini --tools read,bash
