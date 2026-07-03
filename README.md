# Cobrowsing POC

Self-hosted video-streaming cobrowsing для iOS-приложений.

## Структура

```
cobrowsing-poc/
├── docs/
│   ├── architecture.md             # Архитектура + диаграммы
│   └── p0-acceptance-criteria.md   # Тикеты для P0
├── infra/                          # Self-hosted LiveKit deployment
│   ├── docker-compose.yml          # Prod: Caddy + Let's Encrypt + реальные домены
│   ├── docker-compose.dev.yml      # Dev: без TLS, всё на 127.0.0.1
│   ├── livekit.yaml                # Prod-конфиг LiveKit
│   ├── livekit.dev.yaml            # Dev-конфиг LiveKit
│   ├── Caddyfile
│   ├── README.md                   # Как развернуть на VPS
│   └── README.dev.md               # Как поднять локально
├── backend/                        # Token & session API
│   ├── server.js
│   ├── package.json
│   └── .env.example
├── ios/                            # iOS SDK skeleton
│   ├── CobrowseTransport.swift     # Транспорт-нейтральный контракт
│   ├── LiveKitTransport.swift      # Единственный файл с `import LiveKit`
│   ├── CobrowseClient.swift        # Бизнес-логика поверх протокола
│   ├── ConsentPrompt.swift
│   ├── SessionEntryView.swift
│   ├── README.md
│   └── ExampleApp/                 # Тестовое iOS-приложение
│       ├── CobrowseTestApp.swift   # @main + TabView
│       ├── ContentView.swift       # 5 табов + REC-индикатор
│       ├── SessionTab.swift, AnimationTab.swift, FormsTab.swift,
│       │   CanvasTab.swift, ZooTab.swift
│       └── README.md               # Как собрать в Xcode
└── web-agent/                      # Next.js viewer
    ├── app/
    │   ├── page.tsx                # Dashboard
    │   ├── session/[code]/page.tsx # Viewer
    │   └── api/agent/join/route.ts
    ├── package.json
    └── README.md
```

## Quick start

**Dev (localhost, без TLS)** — рекомендуемый первый шаг:

```bash
cd infra
cp .env.dev.example .env.dev
docker compose -f docker-compose.dev.yml --env-file .env.dev up -d
```

Полный dev-flow с web-agent и iOS Simulator — см. [`infra/README.dev.md`](./infra/README.dev.md).

**Prod (публичный VPS с TLS):**

1. Развернуть инфру (см. [`infra/README.md`](./infra/README.md)) — нужен сервер с публичным IP и доменом
2. Запустить backend — настроить `.env` с LiveKit ключами
3. Интегрировать iOS SDK в тестовое приложение (см. [`ios/README.md`](./ios/README.md))
4. Собрать и задеплоить web-agent
5. В iOS-приложении вызвать `CobrowseClient.startSession()` → получить 6-значный код → ввести его в web-agent

## Tech stack

- **iOS**: Swift, ReplayKit (in-app capture), LiveKit Swift SDK
- **Transport**: WebRTC через self-hosted LiveKit
- **Backend**: Node.js, livekit-server-sdk (JWT), Redis (сессии)
- **Web agent**: Next.js 14, LiveKit React components
- **Инфра**: Docker Compose, Caddy (TLS), self-hosted LiveKit + Redis + TURN
