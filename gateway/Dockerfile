FROM node:24-bookworm-slim

ENV NODE_ENV=production
ENV OPENCLAW_HOME=/home/node

RUN npm install -g openclaw@latest

RUN mkdir -p /home/node/.openclaw \
    && chown -R node:node /home/node

USER node
WORKDIR /home/node

EXPOSE 18789

CMD ["openclaw", "gateway"]
