FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY . .
# EXPOSE намеренно не указан: dev-стек использует network_mode: host,
# сервер биндится напрямую на PORT из env (см. infra/docker-compose.dev.yml).
# Для прода (bridge network) EXPOSE добавь при необходимости.
CMD ["node", "server.js"]
