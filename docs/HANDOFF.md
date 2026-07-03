# Handoff: cobrowsing POC

Быстрый брифинг для новой сессии. Читать целиком перед тем, как трогать код.

## Что это

Self-hosted cobrowsing-решение для техподдержки. iOS клиент шарит экран через
ReplayKit → WebRTC → LiveKit SFU → web-agent в браузере у оператора.

Референс — Cobrowse.io. Мы намеренно берём video-streaming подход (не scene-graph),
потому что для POC проще реализовать. Знаем цену: redaction сложнее, bandwidth выше.

## Стек и порты

| Компонент | Порт (dev) | Что делает |
|---|---|---|
| Next.js web-agent | 3000 | Дашборд оператора (в docker) |
| Node.js token-server | **4000** | JWT + жизненный цикл сессии (в docker) |
| LiveKit signaling | 7880 (WS) | WebRTC signaling |
| LiveKit TCP fallback | 7881 | Для сетей без UDP |
| LiveKit media | 50000-60000/udp | WebRTC media |
| Redis | 6379 | State + code→room mapping |

**Backend на 4000, не 3000.** Разнесли специально — Next.js по дефолту 3000.

## Ключевые архитектурные решения

1. **Self-hosted LiveKit, не Cloud.** Для enterprise pitch «развернём в вашем VPC»,
   отсутствие vendor lock-in, фиксированная стоимость VPS.

2. **LiveKit iOS SDK изолирован за `CobrowseTransport` протоколом.**
   Единственный файл с `import LiveKit` — `ios/LiveKitTransport.swift`. Бизнес-логика
   в `CobrowseClient.swift` работает через нейтральный контракт. Миграция на raw
   libwebrtc / mediasoup = один файл + одна строка в `convenience init`.

3. **TURN отключён.** SFU + публичный IP + TCP fallback на 7881 покрывают >95%.
   Возврат TURN — 15 минут работы (закомментированный шаблон в `livekit.yaml`).

4. **Video streaming (ReplayKit), не scene-graph.** Проще реализовать. Осознанно
   отказались от Private-by-Default redaction (у Cobrowse.io это архитектурное
   преимущество scene-graph, для video бессмысленно).

5. **`network_mode: host` для LiveKit** на Docker Desktop for Mac. Без этого UDP
   media теряется в Docker proxy. Нужно включить в Settings → Resources → Network.

6. **Backend URL split.** `LIVEKIT_URL` — что видят клиенты (iOS/web).
   `LIVEKIT_INTERNAL_URL` — куда сам backend ходит за RoomServiceClient.
   В проде совпадают (с ws→http сменой схемы), в dev разные (HOST_IP vs
   host.docker.internal). Оба задаются явно в env — без магического
   `toHttpScheme` fallback в коде.

7. **CORS через функциональный matcher.** Поддерживает `*`, `dev` (любой localhost),
   список origins через запятую. Прямая передача строки `'dev'` в `cors({origin: ...})`
   приводит к тому, что сервер эхом шлёт `Access-Control-Allow-Origin: dev` — invalid.

8. **Единый источник конфига — `infra/.env.dev`.** HOST_IP, порты, LiveKit-ключи,
   CORS, log level — всё в одном файле. `docker-compose.dev.yml` — скелет с
   `${VAR}` интерполяцией, никаких хардкодов IP/портов. `server.js` — все
   env vars required, fail-fast если что-то не задано. Хочешь поменять порт
   token-server или host для реального iPhone — правишь одну строку в .env.dev.

## Структура проекта

```
cobrowsing-poc/
├── docs/
│   ├── architecture.md            # Диаграммы, сетевые требования
│   ├── p0-acceptance-criteria.md  # 8 P0 тикетов Given/When/Then
│   └── HANDOFF.md                 ← вы здесь
├── infra/
│   ├── docker-compose.dev.yml     # Локальный dev — host mode для LiveKit
│   ├── docker-compose.yml         # Prod — с Caddy + Let's Encrypt
│   ├── livekit.dev.yaml           # dev config
│   ├── livekit.yaml               # prod config (TURN закомментирован)
│   ├── Caddyfile
│   ├── .env.dev.example
│   └── README.dev.md              # Пошаговый quickstart для dev
├── backend/
│   ├── server.js                  # Express + JWT + Redis + CORS matcher
│   ├── Dockerfile
│   └── package.json               # "dev": "node --watch server.js"
├── ios/
│   ├── CobrowseTransport.swift    # Нейтральный протокол
│   ├── LiveKitTransport.swift     # LiveKit-реализация (единственный import)
│   ├── CobrowseClient.swift       # State machine, зависит только от протокола
│   ├── ConsentPrompt.swift        # UIAlert consent
│   ├── SessionEntryView.swift     # SwiftUI экран с кодом
│   ├── README.md
│   └── ExampleApp/                # Тестовое iOS-приложение
│       ├── CobrowseTestApp.swift  # @main
│       ├── ContentView.swift      # TabView + REC-индикатор
│       ├── SessionTab.swift, AnimationTab, FormsTab, CanvasTab, ZooTab
│       ├── Info.plist.example
│       └── README.md              # Пошаговый Xcode-setup
└── web-agent/
    ├── app/
    │   ├── page.tsx               # Dashboard
    │   └── session/[code]/page.tsx # Viewer
    ├── lib/api.ts                 # apiFetch + URL валидация
    ├── Dockerfile.dev             # Dev-образ для docker-compose
    └── .env.local.example
```

## Bugs, которые мы уже съели (не повторять)

1. **CORS: `origin: 'dev'` буквально шлётся как ACAO header** → нужен `origin` как
   функция (см. `buildOriginMatcher` в `backend/server.js`).

2. **Port collision 3000** — Next.js и backend оба хотели порт 3000. Backend
   переехал на 4000, поменяли `LIVEKIT_URL` и `NEXT_PUBLIC_API_URL`.

3. **`fetch("undefined/session/list")`** — `NEXT_PUBLIC_API_URL` в `.env.local`
   не задан, `!` в TS ничего не проверяет в рантайме. Фикс: `resolveApiUrl()` в
   `lib/api.ts` с dev-дефолтом и warning.

4. **`http://localhost::3000` в env** — опечатка ломает URL parsing. Фикс:
   `resolveApiUrl` валидирует через `new URL()` и проверяет схему/hostname.

5. **UDP media теряется на Docker Desktop for Mac** → `network_mode: host` для
   LiveKit + включённый "Enable host networking" в Docker Desktop.

6. **`--node-ip 127.0.0.1` ломает ICE** — iOS Simulator не оффрит loopback как
   кандидат, LiveKit оффрит только 127.0.0.1, пересечения нет. Флаг убран,
   LiveKit auto-detect'ит интерфейсы через host networking.

7. **Info.plist генерируется автоматически в Xcode 13+** — либо `INFOPLIST_KEY_*`
   в Build Settings, либо физический файл + `GENERATE_INFOPLIST_FILE=NO`.

## Текущее состояние (2026-07-02)

**Работает:**
- Docker-стек стартует, LiveKit + Redis + token-server поднимаются
- iOS Simulator ↔ backend ↔ LiveKit signaling: успешно
- Web-agent → backend: CORS правильный, `/session/list` работает
- ICE между iOS Simulator и LiveKit коннектится (data channels открываются)
- Ping/pong идёт с rtt ~3ms

**Известный блокер:**
- `RPScreenRecorder.startCapture(handler:)` не эмитит фреймы на iOS Simulator.
  LiveKit SDK ждёт первый sample buffer 10 секунд и таймаутит publish.
- Симптом в LiveKit-логах: session длится ровно 10.077s, `Leave: CLIENT_INITIATED`,
  никаких `AddTrackRequest` от клиента.
- Симптом в iOS-логах: `LocalParticipant._publish [publish] failed... Code=101 "Timed out"`.

## Что дальше

**Немедленно** (закрыть текущий блокер, выбрать один):

- **A. Тест на реальном iPhone** — Xcode Signing & Capabilities, LAN-IP Mac
  (сейчас `192.168.10.1`) в `CobrowseTestApp.swift`. Проверит весь end-to-end.
- **B. Synthetic video source для Simulator dev** — реализовать `VideoCapturer`
  протокол LiveKit с CoreImage-рендерингом (бегущие часы или таймер). ~50-100
  строк. Полный pipeline можно будет отлаживать без реального устройства.
  Переключение real device / simulator через `#if targetEnvironment(simulator)`.

**P1 (после закрытия блокера):**

- **Аннотации** — через LiveKit data channel (`sendData` уже в `CobrowseTransport`).
  Оператор рисует в браузере, точки летят к клиенту, отображаются overlay поверх UI.
- **Voice chat** — mic уже публикуется в SDK, нужно проверить, что оператор слышит.
- **Redaction** — маскировать чувствительные views в pixel buffer до энкодера.
  На iOS: `CustomVideoCapturer` из LiveKit + `CIImage`/Metal shader поверх
  `CMSampleBuffer` от ReplayKit. Есть готовые sensitive-поля в `FormsTab.swift`
  и `ZooTab.swift` как мишени для тестирования.
- **Session recording** — LiveKit Egress (закомментированный сервис в
  `docker-compose.yml`). Server-side запись всей сессии в файл.

**Prod (когда POC пройдёт demo):**

- **Реальный VPS** (рекомендую Hetzner CX22 €4.5/мес) — прогнать `infra/README.md`
- **Caddy + Let's Encrypt** — уже настроено в prod `docker-compose.yml`, нужны домены
- **P0-1 acceptance criteria** — в `docs/p0-acceptance-criteria.md`

## Тестирование матрицы

Example app `CobrowseTestApp` уже покрывает:
- **AnimationTab** — live clock с миллисекундами (для замера латентности между
  iOS и браузером), frame counter, bouncing ball
- **FormsTab** — поля ввода включая мок credit card / CVV — мишени для P1 redaction
- **CanvasTab** — рисование пальцем, gesture responsiveness через стрим
- **ZooTab** — скролл, sheet/alert модалки, sensitive-looking карточки
- **SessionTab** — старт/стоп + REC-badge всегда виден вверху

## Команды-шпаргалка

```bash
# Полный ребут инфры
cd infra
docker compose -f docker-compose.dev.yml down
docker compose -f docker-compose.dev.yml up -d --build --force-recreate

# Логи LiveKit
docker compose -f docker-compose.dev.yml logs livekit --tail 100 -f

# Логи web-agent (Next.js) / token-server
docker compose -f docker-compose.dev.yml logs web-agent --tail 100 -f
docker compose -f docker-compose.dev.yml logs token-server --tail 100 -f

# Диагностический load-test (проверяет, что LiveKit media работает)
docker run --rm --network host livekit/livekit-cli load-test \
  --url ws://127.0.0.1:7880 \
  --api-key APIdevkeydevkey \
  --api-secret devsecret_at_least_32_chars_replace_before_commit_pls \
  --duration 15s --video-publishers 1

# Web-agent вне docker (если нужно дебажить локально)
docker compose -f docker-compose.dev.yml stop web-agent
cd web-agent && npm install && npm run dev

# Проверить CORS правильно работает
curl -i -X OPTIONS http://127.0.0.1:4000/session/list \
  -H 'Origin: http://localhost:3000' \
  -H 'Access-Control-Request-Method: GET'
```

## Личные предпочтения

Пользователь предпочитает concise-стиль. Не разжёвывать очевидное. Прогонять
диагностику до предложения фиксов (не гадать вслепую). Использовать TaskCreate
для многошаговой работы. Показывать файлы через `mcp__cowork__present_files`.

## Что НЕ трогать без хорошего повода

- `CobrowseTransport` протокол — стабильный контракт, миграция на другой транспорт
  строится на нём. Ломать API — переписывать бизнес-логику.
- `--node-ip` в `docker-compose.dev.yml` — уже вынесено, добавление обратно ломает
  ICE (см. bug #6).
- `network_mode: host` — критично для UDP media path.
- Prod `docker-compose.yml` — не трогаем без обсуждения, отдельная связка.
