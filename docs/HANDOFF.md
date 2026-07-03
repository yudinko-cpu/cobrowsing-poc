# Handoff: cobrowsing POC

Быстрый брифинг для новой сессии. Читать целиком перед тем, как трогать код.

Последнее обновление: 2026-07-03. **Следующая итерация — VPS-развёртывание (P0-1).**

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

## Что работает (dev-стек, локально)

- Полный e2e на реальном iPhone (LAN) + Chrome/Safari (127.0.0.1) — экран
  клиента виден у оператора, аудио идёт обеими сторонами (если включить mic
  кнопкой в хедере)
- Docker-стек поднимается одной командой, hot reload и для backend и для web-agent
- iOS state machine restartable — старт/стоп/старт без рестарта приложения
- LiveKit auto-reconnect отражается в UI как `.reconnecting(code)`
- `/agent/join` идемпотентен по (code, agentId) — F5 в браузере, StrictMode
  double-mount, ретраи — всё OK
- Web-agent HUD показывает всё для диагностики: connection state, ICE/PC state,
  участников, треки, codec/bitrate/fps/RTT/total bytes

## Что НЕ работает / имеет workaround

Всё нижеперечисленное — свойство dev-окружения. В prod (VPS + HTTPS + реальные
домены) эти проблемы исчезают.

1. **iOS Simulator + ReplayKit** — `startCapture` не эмитит фреймы. Publish
   таймаутит на 10с.
   → Workaround: тестировать на реальном iPhone.

2. **Docker Desktop for Mac + LAN HOST_IP + Safari** — ICE не собирается.
   Причины: (a) Docker Desktop не даёт true host networking — LiveKit видит
   только VM-интерфейсы (192.168.65.x), не Mac's LAN IP; (b) Safari прячет
   host-кандидаты через mDNS-обфускацию; NAT hairpin через public IP не работает.
   → Workaround: web-agent открывать через `http://127.0.0.1:3000` (не через
   LAN IP), в Chrome (не Safari). Backend fetch cross-origin — CORS matcher `dev`
   разрешает 127.0.0.1 origin к любому backend IP.

3. **Insecure origin (HTTP на LAN IP) + микрофон** — Chrome/Safari блокируют
   `getUserMedia` на HTTP кроме localhost/127.0.0.1.
   → Web-agent: `audio={false}` на LiveKitRoom (не тянет мик при коннекте),
   MicToggle кнопка в хедере — юзер сам включит если secure context, при
   отказе показывает расшифровку. `InsecureContextBanner` предупреждает.

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

9. **iOS backendURL — `ios/CobrowseTestApp/app/AppConfig.swift`.** Дефолт
   `127.0.0.1:4000` (Simulator/localhost). Для реального iPhone — override
   через Scheme → Arguments `-CobrowseBackendURL http://<LAN-IP>:4000`, без
   правки кода. Хардкод URL в трёх местах (main + 2 Preview'а) больше не живёт.

10. **iOS state machine — restartable, aware of reconnect.**
    Состояния: `idle | requestingConsent | connecting | streaming(code) |
    reconnecting(code) | ended | error(msg)`. Ключевые свойства:
    * `startSession()` можно звать из любого терминального (`idle/ended/error`)
      — не нужен рестарт приложения после стопа или сбоя.
    * Авто-reconnect LiveKit'а мостится в `.reconnecting(code)` — пользователь
      видит "восстанавливаем связь", а не тишину.
    * `didDisconnectWithReason` различает пользовательский стоп (`.ended`),
      сетевую потерю, серверное закрытие, tokenExpired — каждый со своим
      осмысленным сообщением, а не всё в `.ended`.
    * `stopSession()` делает best-effort `POST /session/end` на backend —
      LiveKit room закрывается, дашборд оператора обновляется.

11. **`/agent/join` идемпотентен по `(code, agentId)`.** Первый claim фиксирует
    `claimedByAgentId`, продлевает TTL кода до `SESSION_TTL_SECONDS`. Повторный
    join с тем же agentId — переизлучаем токен (та же identity, LiveKit
    заменяет участника). Другой agentId → 409. Это делает viewer устойчивым
    к React StrictMode double-mount, F5 в браузере и network retry — без
    компромисса для anti-hijack. Web-agent persist'ит `agentId` в
    `sessionStorage` — F5 сохраняет identity.

12. **Web-agent viewer расширяет track filter.** Вместо `useTracks([ScreenShare])`
    использует `useRemoteParticipants()` + fallback на любой video-source
    (устойчиво к SDK-мисматчам source metadata). Плюс полный HUD с ICE state
    и стримовой статистикой — левый нижний угол viewer'а.

## Структура проекта

```
cobrowsing-poc/
├── docs/
│   ├── architecture.md            # Диаграммы, сетевые требования
│   ├── p0-acceptance-criteria.md  # 8 P0 тикетов Given/When/Then (свежий)
│   └── HANDOFF.md                 ← вы здесь
├── infra/
│   ├── docker-compose.dev.yml     # dev: host mode для LiveKit, ${VAR} интерполяция
│   ├── docker-compose.yml         # prod: Caddy + Let's Encrypt (НЕ соответствует
│   │                              #       новому required-env-only server.js!)
│   ├── livekit.dev.yaml           # dev config
│   ├── livekit.yaml               # prod config (TURN закомментирован)
│   ├── Caddyfile
│   ├── .env.dev.example           # Единый источник dev-конфига
│   └── README.dev.md              # Пошаговый quickstart для dev
├── backend/
│   ├── server.js                  # Express + JWT + Redis + CORS matcher.
│   │                              # Все env vars required (fail-fast).
│   ├── .env.example               # Прод/standalone-запуск
│   ├── Dockerfile                 # prod: node server.js
│   └── package.json               # "dev": "node --watch server.js"
├── ios/
│   └── CobrowseTestApp/
│       ├── sdk/
│       │   ├── CobrowseTransport.swift    # Нейтральный протокол
│       │   ├── LiveKitTransport.swift     # Единственный import LiveKit
│       │   ├── CobrowseClient.swift       # State machine
│       │   ├── ConsentPrompt.swift        # UIAlert consent
│       │   └── SessionEntryView.swift     # SwiftUI экран с кодом
│       ├── app/
│       │   ├── CobrowseTestApp.swift      # @main
│       │   ├── AppConfig.swift            # backendURL + UserDefaults override
│       │   ├── ContentView.swift          # TabView + REC-badge (streaming/reconnecting)
│       │   ├── SessionTab.swift, AnimationTab, FormsTab, CanvasTab, ZooTab
│       │   └── Info.plist                 # ATS + Mic/Camera usage
│       └── README.md              # Пошаговый Xcode-setup
└── web-agent/
    ├── app/
    │   ├── page.tsx               # Dashboard: input + список сессий (5s polling)
    │   └── session/[code]/page.tsx # Viewer + HUD + MicToggle + InsecureBanner
    ├── lib/api.ts                 # apiFetch + URL валидация
    ├── Dockerfile.dev             # Dev-образ для docker-compose
    ├── .dockerignore
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

8. **React StrictMode + одноразовый `/agent/join`** — в dev Next.js `useEffect`
   фаерится дважды. Первый POST /agent/join удалял код из Redis, второй получал
   404 "code not found or expired" → UI показывал ошибку, хотя iOS уже в комнате.
   Фикс: (a) backend не удаляет код, помечает `claimedByAgentId` и позволяет
   тому же agentId переклаймить; (b) `agentId` persist через `sessionStorage`,
   чтобы F5 не генерил новую identity; (c) useRef guard от double-mount.

9. **LiveKit CSS `object-fit: cover` растягивает video.** Дефолт для
   `.lk-participant-media-video` — cover. Наш inline `objectFit: contain` не
   бил из-за specificity. Фикс: `.cobrowse-video` класс с `!important` +
   `minHeight: 0` на flex-item, иначе intrinsic-размер video высаживает контейнер
   за viewport (нужен скролл).

10. **Web-agent на insecure origin + `audio={true}` роняет сессию.** `LiveKitRoom`
    с `audio={true}` тянет `getUserMedia` при коннекте, на HTTP LAN-IP Chrome
    отказывает с `NotAllowedError`, вся сессия уходит в fatal error. Фикс:
    `audio={false}` + MicToggle с opt-in клика.

## VPS-развёртывание (P0-1) — что делать в следующей сессии

### Готово

- `infra/docker-compose.yml` — prod compose с Caddy + Let's Encrypt (базовый скелет)
- `infra/livekit.yaml` — prod LiveKit config
- `infra/Caddyfile` — reverse proxy config

### НУЖНО ПОПРАВИТЬ ПЕРЕД ДЕПЛОЕМ

Prod `docker-compose.yml` был написан ДО того, как мы сделали `server.js`
required-only. Сейчас там не хватает env vars:

```yaml
# infra/docker-compose.yml, service token-server, нужно добавить:
environment:
  PORT: 4000
  LIVEKIT_INTERNAL_URL: http://livekit:7880   # или host.docker.internal:7880
  LOG_LEVEL: info
```

Иначе server.js упадёт на старте с `Missing env: PORT` / `LIVEKIT_INTERNAL_URL`
/ `LOG_LEVEL`. Плюс убрать `web-agent` из prod-стека не забыть (или добавить —
сейчас его нет, нужно решить как деплоить фронт: тот же контейнер что и dev
но с `next build && next start`, отдельный host, Vercel, или Caddy-static).

Также в prod compose есть `--node-ip ${PUBLIC_IP}` для LiveKit — это правильно
для VPS с единственным публичным IP.

### План развёртывания

1. **VPS**. Рекомендация из старой версии HANDOFF — Hetzner CX22 (€4.5/мес,
   2 vCPU, 4GB, безлимитный трафик). Ubuntu 22.04. Публичный IPv4.

2. **DNS**. Три A-записи:
   - `livekit.example.com` → VPS IP
   - `api.cobrowse.example.com` → VPS IP
   - `agent.cobrowse.example.com` → VPS IP

3. **Firewall (ufw / hetzner cloud firewall):**
   - 22/tcp (SSH)
   - 80/tcp, 443/tcp (Caddy для HTTPS + LiveKit signaling через WSS)
   - 7881/tcp (LiveKit TCP fallback)
   - 50000-60000/udp (LiveKit media)
   - Redis (6379) и token-server (4000) — НЕ должны быть открыты снаружи
     (bind на 127.0.0.1 в compose)

4. **`.env` на VPS**. Скопировать пример из `backend/.env.example`,
   заполнить:
   ```
   DOMAIN=livekit.example.com
   API_DOMAIN=api.cobrowse.example.com
   AGENT_DOMAIN=agent.cobrowse.example.com
   PUBLIC_IP=<VPS public IPv4>
   LIVEKIT_API_KEY=<openssl rand -hex 16>
   LIVEKIT_API_SECRET=<openssl rand -base64 32>
   PORT=4000
   LIVEKIT_INTERNAL_URL=http://host.docker.internal:7880
   LOG_LEVEL=info
   ```
   Синхронизировать key/secret в `livekit.yaml` (пока не автоматизировано —
   flag в bugs).

5. **Web-agent в prod.** Решить: (a) docker service `next build && next start`
   в том же compose; (b) отдельный CDN/Vercel. Для POC — вариант (a), но
   надо добавить сервис в prod compose.

6. **Deploy check-list (P0-1 AC):**
   - [ ] `docker compose up -d` — все 4 контейнера `Up healthy` через 60с
   - [ ] `curl https://livekit.example.com/` → 200 + `X-LiveKit-Version`
   - [ ] `curl https://api.cobrowse.example.com/health` → `{"ok":true}`
   - [ ] `livekit-cli load-test --duration 30s` — 1 трек публикуется, без ICE
   - [ ] `nmap` извне: открыты только 80, 443, 7881, 50000-60000/udp; Redis
     и token-server закрыты
   - [ ] iOS с реального iPhone → продовский `api.cobrowse.example.com` →
     оператор с Mac Chrome на `agent.cobrowse.example.com` → видео идёт,
     `getUserMedia` больше не блокируется (secure context!)

7. **Опционально:** дописать GitHub Actions деплой на push в main (SSH + docker
   compose pull + up). Или Watchtower.

### Остальные P0-задачи, которые лучше добить параллельно/до VPS

- **P0-2 edge cases** — сворачивание приложения → `.ended`, iPad native resolution
- **P0-3** — прервать сеть на 5с руками, убедиться что reconnect-state работает
- **P0-6** — VoiceOver + юридическое ревью текста consent'а

### P1 после P0

- **Аннотации** — через LiveKit data channel (`sendData` уже в `CobrowseTransport`).
  Оператор рисует в браузере, точки летят к клиенту, overlay поверх UI.
- **Voice chat** — уже работает через MicToggle в web-agent.
- **Redaction** — маскировать чувствительные views в pixel buffer до энкодера.
  На iOS: `CustomVideoCapturer` из LiveKit + `CIImage`/Metal shader поверх
  `CMSampleBuffer` от ReplayKit. Готовые sensitive-поля в `FormsTab.swift`
  и `ZooTab.swift` как мишени.
- **Session recording** — LiveKit Egress (закомментированный сервис в
  `docker-compose.yml`). Server-side запись всей сессии в файл.
- **Реальная авторизация агентов** — сейчас `agentId = agent-<random>` в
  sessionStorage. Заменить на JWT из SSO/OAuth (упомянуто в TODO web-agent).

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
# --- DEV STACK ---

cd infra
cp .env.dev.example .env.dev    # один раз

# Полный ребут инфры
docker compose -f docker-compose.dev.yml --env-file .env.dev down
docker compose -f docker-compose.dev.yml --env-file .env.dev up -d --build --force-recreate

# Логи
docker compose -f docker-compose.dev.yml logs livekit --tail 100 -f
docker compose -f docker-compose.dev.yml logs web-agent --tail 100 -f
docker compose -f docker-compose.dev.yml logs token-server --tail 100 -f

# Web-agent открывать в Chrome через http://127.0.0.1:3000 (не через LAN IP)
# — Safari + insecure LAN origin убивает ICE (см. известные проблемы #2).

# Web-agent вне docker (если нужно дебажить локально)
docker compose -f docker-compose.dev.yml stop web-agent
cd web-agent && npm install && npm run dev

# --- ДИАГНОСТИКА ---

# LiveKit media path (не завязано на клиентов)
docker run --rm --network host livekit/livekit-cli load-test \
  --url ws://127.0.0.1:7880 \
  --api-key APIdevkeydevkey \
  --api-secret devsecret_at_least_32_chars_replace_before_commit_pls \
  --duration 15s --video-publishers 1

# CORS работает
curl -i -X OPTIONS http://127.0.0.1:4000/session/list \
  -H 'Origin: http://localhost:3000' \
  -H 'Access-Control-Request-Method: GET'

# Создать тестовую сессию
curl -X POST http://127.0.0.1:4000/session/create -H 'Content-Type: application/json' -d '{}'

# Chrome WebRTC internals
# → chrome://webrtc-internals
# смотрим iceconnectionstatechange, candidate pairs

# --- iOS ---

# Реальный iPhone на LAN:
# 1. В infra/.env.dev: HOST_IP=<LAN IP Mac> (ipconfig getifaddr en0)
# 2. В Xcode Scheme → Run → Arguments Passed On Launch:
#    -CobrowseBackendURL http://<LAN IP>:4000
# 3. docker compose restart token-server web-agent
```

## Личные предпочтения

Пользователь предпочитает concise-стиль. Не разжёвывать очевидное. Прогонять
диагностику до предложения фиксов (не гадать вслепую). Использовать TaskCreate
для многошаговой работы. Показывать файлы через `mcp__cowork__present_files`.

## Что НЕ трогать без хорошего повода

- `CobrowseTransport` протокол — стабильный контракт, миграция на другой транспорт
  строится на нём. Ломать API — переписывать бизнес-логику.
- `--node-ip` в `docker-compose.dev.yml` — уже вынесено, добавление обратно ломает
  ICE (см. bug #6). В prod compose стоит `${PUBLIC_IP}` — это правильно.
- `network_mode: host` — критично для UDP media path и в dev, и в prod.
- **`server.js` "required-only" стиль** — не добавляй fallback-дефолты. Все env
  задаются явно через compose. Иначе теряется fail-fast и растёт неявная магия.
- **`/agent/join` идемпотентность** — не откатывай на "код одноразовый", это
  ломает StrictMode/F5/retry. Если нужен anti-hijack — уже есть проверка
  `claimedByAgentId`.
