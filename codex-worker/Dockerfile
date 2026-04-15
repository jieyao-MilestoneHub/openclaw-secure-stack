FROM node:24-bookworm-slim

ENV NODE_ENV=production

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @openai/codex@latest

RUN mkdir -p /workspace /tmp \
    && chown -R node:node /workspace /tmp /home/node

USER node
WORKDIR /workspace

CMD ["sh", "-c", "sleep infinity"]
