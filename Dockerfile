FROM node:22-slim

# ─── System Dependencies ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    git \
    python3 \
    python-is-python3 \
    ca-certificates \
    bash \
    && rm -rf /var/lib/apt/lists/*

# ─── Create non-root user ────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash claw
WORKDIR /home/claw

# ─── Install OpenClaw ─────────────────────────────────────────────────────────
RUN npm install -g openclaw@latest

# ─── Persistent data directory (Railway volume mount target) ──────────────────
RUN mkdir -p /data/.openclaw /data/workspace/skills /data/workspace/memory \
    && chown -R claw:claw /data

# ─── Copy configuration files ────────────────────────────────────────────────
COPY --chown=claw:claw openclaw.json /data/.openclaw/openclaw.json
COPY --chown=claw:claw workspace/ /data/workspace/

# ─── Copy startup script ─────────────────────────────────────────────────────
COPY --chown=claw:claw startup.sh /home/claw/startup.sh
RUN chmod +x /home/claw/startup.sh

# ─── Copy YieldClaw skill files ───────────────────────────────────────────────
COPY --chown=claw:claw skill-files/ /home/claw/skill-files/

# ─── Environment ──────────────────────────────────────────────────────────────
ENV OPENCLAW_STATE_DIR=/data/.openclaw
ENV OPENCLAW_WORKSPACE_DIR=/data/workspace
ENV OPENCLAW_GATEWAY_PORT=18789
ENV PORT=8080
ENV NODE_ENV=production
ENV NODE_OPTIONS="--max-old-space-size=512"

USER claw

EXPOSE 8080 3402

ENTRYPOINT ["/home/claw/startup.sh"]
