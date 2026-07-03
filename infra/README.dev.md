# Локальный dev-стек

Полная связка `iOS Simulator ↔ backend ↔ LiveKit` без публичного сервера,
без TLS, без Caddy. Только `docker compose` + iOS Simulator + браузер.

Продакшн-инструкция — в [`README.md`](./README.md).

## Что запускается

| Компонент | Порт | Как достучаться |
|---|---|---|
| LiveKit signaling | `ws://127.0.0.1:7880` | iOS SDK, web-agent |
| LiveKit TCP fallback | `127.0.0.1:7881` | если UDP не проходит |
| LiveKit WebRTC media | UDP `127.0.0.1:50000-50100` | автоматически через ICE |
| Token server | `http://127.0.0.1:4000` | iOS SDK, web-agent |
| Redis | `127.0.0.1:6379` | только внутренний |
| Web-agent (Next.js) | `http://127.0.0.1:3000` | оператор в браузере |

Всё биндится **только на 127.0.0.1** — наружу ничего не торчит.

**Порты специально разнесены:** Next.js на 3000 (по дефолту), backend на 4000.
Если поменять их местами — Next.js упадёт в 3001 (или backend не встанет),
и получишь классический баг «fetch попадает в Next.js вместо API, а тот отдаёт
404 без CORS-заголовков → браузер репортит как CORS error».

## Требования

- Docker Desktop 4.29+ (macOS/Windows) или Docker Engine (Linux)
- ~2 ГБ свободной RAM для контейнеров
- Свободные порты: 3000, 4000, 6379, 7880, 7881, 50000-60000/udp
- **На macOS/Windows**: в Docker Desktop → Settings → Resources → Network
  включить **«Enable host networking»** (без него не работает WebRTC-media).
  На Linux эта опция не нужна.

## Шаги

### 1. Стартовать инфру

```bash
cd infra
cp .env.dev.example .env.dev

# (опционально) сгенерировать свои ключи вместо дефолтных
# и вписать их в .env.dev + livekit.dev.yaml

# Первый запуск — обязательно с --build, чтобы собрать образ token-server.
# .env.dev подхватывается автоматически через env_file: в compose-файле.
docker compose -f docker-compose.dev.yml up -d --build
docker compose -f docker-compose.dev.yml logs -f livekit
```

Ожидаем в логах LiveKit: `starting LiveKit server` + `WebRTC service started`.

**Про hot reload backend:** исходники `backend/` смонтированы в контейнер
через bind-mount, а сервис запускается через `node --watch server.js`. Правки в
`server.js` применяются автоматически без пересборки образа. `docker compose build`
нужен только когда меняешь `package.json` (добавляешь npm-зависимость).

**Про hot reload web-agent:** аналогично — `../web-agent` смонтирован в контейнер,
Next.js dev server ловит изменения через polling (`WATCHPACK_POLLING=true`, иначе
на Docker Desktop for Mac inotify не пробрасывается через FUSE и hot reload молчит).
Правки в `.tsx`/`.ts` подхватываются. Исключение: изменения `NEXT_PUBLIC_*`
переменных — Next.js читает их только на старте, нужен рестарт контейнера
(`docker compose restart web-agent`).

**Забыл `--build` — получишь классический "сервер не подхватил изменения".**
Если что-то в backend'е странно себя ведёт после правок кода: `docker compose logs token-server`,
и если версия сервиса подозрительно старая — `docker compose up -d --build --force-recreate`.

### 2. Проверить health

```bash
# Token server
curl http://127.0.0.1:4000/health
# → {"ok":true}

# LiveKit WebSocket accepts upgrade
curl -i http://127.0.0.1:7880/
# → HTTP/1.1 200 OK, X-LiveKit-Version: ...

# Создать тестовую сессию
curl -X POST http://127.0.0.1:4000/session/create -H 'Content-Type: application/json' -d '{}'
# → {"code":"482-619","roomName":"cobrowse-...","livekitUrl":"ws://127.0.0.1:7880","token":"eyJ...","expiresIn":600}
```

Если `curl /session/create` возвращает `500` — смотрим `docker compose logs token-server`.
Чаще всего: `Missing env` или `Redis connection refused` (сервисы стартанули не в том порядке).

### 3. Web-agent

Web-agent стартует вместе с инфрой (сервис `web-agent` в compose). Отдельный
терминал больше не нужен. Первый запуск `docker compose up --build` соберёт
образ с `node_modules` (несколько минут); дальше стек поднимается за секунды.

Открыть `http://127.0.0.1:3000`. Ввести код из шага 2 → должна открыться viewer-страница.
Пока iOS не подключился — увидим плейсхолдер «Ждём, пока клиент начнёт делиться экраном».

Если хочется запустить web-agent вне docker (например, чтобы дебажить через
`next dev --turbo` или посмотреть точные webpack-ошибки в терминале):

```bash
docker compose -f docker-compose.dev.yml stop web-agent
cd ../web-agent
cp .env.local.example .env.local   # NEXT_PUBLIC_API_URL=http://127.0.0.1:4000
npm install && npm run dev
```

### 4. iOS Simulator

В Xcode-проекте, куда встраиваете SDK:

**a.** Скопировать `NSAppTransportSecurity` секцию из [`ios/Info.plist.dev.example`](../ios/Info.plist.dev.example)
в Info.plist приложения. Без этого iOS будет блокировать `ws://` подключение.

**b.** Инициализировать клиент с локальным backend'ом:

```swift
let client = CobrowseClient(
    backendURL: URL(string: "http://127.0.0.1:4000")!
)
```

**c.** Запустить приложение на Simulator, нажать «Запустить сессию», подтвердить consent.
На экране появится 6-значный код.

**d.** Ввести код в web-agent → в браузере появится видео Simulator'а.

## Симптомы и что делать

**`docker compose up` падает на livekit**  
Скорее всего, конфликт портов. Проверить `lsof -i :7880 -i :4000 -i :6379`.

**`/session/create` возвращает 500, в логах "Missing env"**  
`.env.dev` не подхватился. Убедиться, что запускали с `--env-file .env.dev`.

**`/session/create` работает, но iOS падает с "The resource could not be loaded"**  
ATS блокирует `ws://`. Проверить, что `NSAllowsLocalNetworking` в Info.plist приложения.

**iOS видит state `.connecting` бесконечно**  
LiveKit signaling не отвечает. Проверить `docker compose logs livekit` — там должны быть строки про новое соединение при попытке подключения. Если тишина — Simulator не смог достучаться до `ws://127.0.0.1:7880`. Обычно из-за ATS или из-за того, что `LIVEKIT_URL` вернулся с `host.docker.internal` вместо `127.0.0.1` (проверить env token-server).

**iOS подключился, но `.streaming` не наступает / видео не идёт**  
Signaling OK, media не идёт. Признак в iOS-логах: `[publish] failed ... Code=101 "Timed out"`.
Проверить:
- Docker Desktop → Settings → Resources → Network → **Enable host networking** включено?
  Без этого UDP-медиа проходит через Docker proxy и WebRTC ломается на Mac
- `docker compose -f docker-compose.dev.yml logs livekit --tail 100 | grep -i ice` —
  ищем `no compatible ICE candidates` / `ICE gathering timeout` / `selected candidate pair`
- LiveKit контейнер стартовал в host mode? `docker inspect infra-livekit-1 | grep NetworkMode`
  должно вернуть `"host"`
- Прогнать load-test изнутри Docker (проверяет media path без iOS):
  ```bash
  docker run --rm --network host livekit/livekit-cli load-test \
    --url ws://127.0.0.1:7880 \
    --api-key APIdevkeydevkey \
    --api-secret devsecret_at_least_32_chars_replace_before_commit_pls \
    --duration 15s --video-publishers 1
  ```
  Если тоже фейлится — проблема в Docker networking. Если работает — что-то
  специфичное для iOS Simulator (проверить ATS в Info.plist)

**Web-agent подключается, iOS подключается, но они друг друга не видят**  
Разные комнаты. Проверить в логах token-server, что `roomName` в publisher-токене (для iOS)
и в subscriber-токене (для агента) совпадают.

**CORS ошибка типа "Access-Control-Allow-Origin: dev" is invalid value**  
Контейнер token-server работает со старым кодом (без функционального CORS matcher'а).
С hot reload через `node --watch` это не должно повторяться, но если случилось:
`docker compose -f docker-compose.dev.yml up -d --build --force-recreate token-server`.

## Полная перезагрузка

```bash
cd infra
docker compose -f docker-compose.dev.yml down -v   # -v сотрёт Redis
docker compose -f docker-compose.dev.yml --env-file .env.dev up -d --force-recreate
```

## Как перейти на прод-стек

Прод-стек в `docker-compose.yml` использует реальный домен + Caddy + Let's Encrypt.
Ключевые отличия от dev:

| | Dev | Prod |
|---|---|---|
| TLS | нет | Let's Encrypt через Caddy |
| Домены | 127.0.0.1 | реальные |
| Caddy | не запускается | reverse proxy для API и WS |
| LIVEKIT_URL | `ws://127.0.0.1:7880` | `wss://livekit.example.com` |
| Порты наружу | 0 | 80, 443, 7881/tcp, 50000-60000/udp |
| iOS ATS | `NSAllowsLocalNetworking=true` | не требуется |

Смена dev → prod = смена `backendURL` в iOS-приложении и `.env` файла для docker-compose.
Никаких изменений в коде SDK или backend не нужно.
