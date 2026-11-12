FROM python:3.12.12-slim-bookworm@sha256:593bd06efe90efa80dc4eee3948be7c0fde4134606dd40d8dd8dbcade98e669c
COPY deploy/gateway.py /app/gateway.py
USER 1000:1000
ENTRYPOINT ["python3", "-u", "/app/gateway.py"]
