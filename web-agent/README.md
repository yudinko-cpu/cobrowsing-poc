# Web Agent (Next.js)

Dashboard для операторов техподдержки.

## Что покрыто (P0)

- `app/page.tsx` — главный экран: ввод 6-значного кода + список активных сессий
- `app/session/[code]/page.tsx` — viewer: подключение к LiveKit, отображение видео клиента, voice chat
- `app/api/agent/join/route.ts` — прокси к backend (опционально, можно ходить на API напрямую с CORS)

## Локальный запуск

Дефолтный путь — вместе с dev-стеком через `docker compose -f infra/docker-compose.dev.yml up --build`.
Web-agent поднимется как сервис `web-agent`, слушает `http://127.0.0.1:3000`, hot reload
работает через bind-mount и polling. Никаких `npm install` руками.

Если нужен запуск вне docker (например, для дебага webpack-ошибок в терминале):

```bash
cp .env.local.example .env.local
# Прописать NEXT_PUBLIC_API_URL=http://127.0.0.1:4000

npm install
npm run dev   # http://localhost:3000
```

## Деплой (для POC)

Простой вариант: `next build && next export → /srv/web-agent`, Caddy раздаёт статику. См. `infra/Caddyfile`.

Для prod — Vercel, Netlify, или Docker-контейнер с `next start`.
