# Prod-образ web-agent. Отдельный от Dockerfile.dev — тот только для hot-reload
# внутри docker compose dev-стека.
#
# Multi-stage:
#   deps    — только node_modules, кэшируется до тех пор пока package.json стабилен
#   builder — прогоняет `next build` с NEXT_PUBLIC_* build-args (см. ниже)
#   runner  — минимальный слой на `next start`, без dev-deps и без исходников
#
# NEXT_PUBLIC_API_URL — обязательный build-arg. Next.js подставляет NEXT_PUBLIC_*
# на этапе сборки в бандл, не на рантайме. Если забыть — все fetch'и уйдут в
# dev-дефолт (см. web-agent/lib/api.ts). GHA-workflow передаёт его из
# repository variable NEXT_PUBLIC_API_URL.

FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci

FROM node:24-alpine AS builder
WORKDIR /app
ARG NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
# Fail-fast если build-arg забыли: не хотим втихую собрать образ с undefined URL.
RUN test -n "$NEXT_PUBLIC_API_URL" || (echo "NEXT_PUBLIC_API_URL build-arg required" && exit 1)
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# Next.js не требует public/, но runner COPY --from=builder /app/public
# упадёт без неё. Гарантируем — пустая папка бесплатна.
RUN mkdir -p /app/public
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# Тот же тег базового образа, что и в deps/builder: иначе CI тянет и кэширует
# два разных base-слоя вместо одного.
FROM node:24-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
# standalone-сервер читает порт/хост из env, а не из аргументов CLI.
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# next.config.mjs: output: 'standalone' — Next трассирует рантайм-зависимости и
# кладёт самодостаточный server.js + минимальный node_modules в .next/standalone.
# Копируем только его: полный node_modules (290 МБ, с devDependencies) в прод-образ
# не едет. Меньше слой → быстрее exporting layers, push в GHCR и экспорт GHA-кэша.
#
# .next/static и public/ в standalone НЕ входят — копируем отдельно, порядок важен:
# сначала standalone (он создаёт ./.next), потом static внутрь него.
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static

EXPOSE 3000
CMD ["node", "server.js"]
