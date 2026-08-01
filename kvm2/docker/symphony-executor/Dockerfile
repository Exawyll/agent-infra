FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
# Without this, Python's stdout is fully buffered (no TTY attached) — print()
# calls sit in the buffer and never reach `docker logs` until it fills up.
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y \
    python3 python3-pip git curl wget jq ca-certificates gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y nodejs \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install hermes directly if needed, or assume it is mounted at /usr/local/bin/hermes
# Let's download a placeholder script just in case, but rely on volume mount.
# The user can override it.

WORKDIR /app
COPY scripts/symphony-executor.py /app/symphony-executor.py
RUN chmod +x /app/symphony-executor.py

CMD ["python3", "/app/symphony-executor.py"]
