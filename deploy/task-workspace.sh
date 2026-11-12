#!/bin/sh
set -eu
cp -R /input/. /workspace/
find /workspace -mindepth 1 -exec chmod u+w {} +
touch /tmp/copilot-workspace-ready
exec sleep 86400
