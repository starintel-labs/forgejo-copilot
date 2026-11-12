FROM node:22.23.0-bookworm-slim@sha256:d9f850096136edbc402debdd8729579a288aac64574ada0ff4db26b6ae58b0b2
RUN apt-get update && apt-get install -y --no-install-recommends python3 git sbcl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global --ignore-scripts @earendil-works/pi-coding-agent@1.5.2 \
    && npm cache clean --force
COPY deploy/pi-models.json /opt/copilot/models.json
COPY deploy/pi-entrypoint.sh /opt/copilot/entrypoint.sh
COPY deploy/task-workspace.sh /opt/copilot/task-workspace.sh
USER 1000:1000
WORKDIR /workspace
ENV HOME=/tmp/home PI_CODING_AGENT_DIR=/tmp/home/.pi/agent PI_TELEMETRY=0
ENTRYPOINT ["/bin/sh", "/opt/copilot/entrypoint.sh"]
