# P0 Acceptance Criteria

Тикеты готовы к копированию в Jira/Linear. Каждый AC формулирован в формате Given/When/Then.

---

## P0-1 — Self-hosted LiveKit развёрнут

**Описание.** Развернуть LiveKit, Redis и Caddy на одном VPS, доступ через HTTPS-домены.

**Acceptance criteria**

- **Given** чистый Ubuntu 22.04 VPS с публичным IP и тремя поддоменами (livekit, api, agent) **When** выполнить `docker compose up -d` из `infra/` **Then** все 4 контейнера (livekit, redis, token-server, caddy) в статусе `Up healthy` через 60 сек
- **Given** запущенный стек **When** `curl https://livekit.example.com/` **Then** возвращается 200 с заголовком `X-LiveKit-Version`
- **Given** запущенный стек **When** `curl https://api.cobrowse.example.com/health` **Then** возвращается `{"ok":true}`
- **Given** запущенный стек **When** запустить `livekit-cli load-test --duration 30s` **Then** успешно публикуется хотя бы 1 тестовый трек, без ошибок ICE
- **Given** запущенный стек **When** сканировать порты nmap извне **Then** наружу открыты только 80, 443, 7881, 3478, 5349, диапазон UDP 50000-60000. Redis (6379) и token-server (3000) недоступны снаружи

**Артефакты:** `infra/docker-compose.yml`, `infra/livekit.yaml`, `infra/Caddyfile`, `infra/README.md`

**Оценка:** 2 дня (1 день первая попытка + 1 день дебаг сети)

---

## P0-2 — Capture экрана через ReplayKit (in-app)

**Описание.** iOS SDK должен запускать ReplayKit in-app screen recording и получать CMSampleBuffer'ы видео-фреймов.

**Acceptance criteria**

- **Given** iOS-приложение с интегрированным SDK на iOS 14+ **When** вызвать `RPScreenRecorder.shared().startCapture(...)` **Then** в handler приходят `CMSampleBuffer` с типом `.video`, не реже 10 fps
- **Given** идёт capture **When** пользователь сворачивает приложение **Then** SDK получает `didStopRecordingWith error` и переводит state в `.ended`
- **Given** идёт capture **When** придёт audio sample buffer от ReplayKit **Then** SDK его игнорирует (микрофон публикуется отдельным треком через AVAudioSession)
- **Given** iPad с iOS 14+ **When** запустить capture **Then** разрешение нативное устройства, не масштабируется

**Артефакты:** `ios/CobrowseClient.swift` (метод `startSession`)

**Зависимости:** P0-1

**Оценка:** 1 день

---

## P0-3 — Публикация video-трека в LiveKit Room

**Описание.** Подключиться к LiveKit Room и опубликовать screen-share трек из CMSampleBuffer'ов ReplayKit.

**Acceptance criteria**

- **Given** валидный JWT-токен с правами `canPublish` **When** вызвать `room.connect(url, token)` **Then** `room.connectionState == .connected` в течение 3 сек на 4G
- **Given** подключённый Room **When** опубликовать screen-share track с `useBroadcastExtension: false` **Then** в LiveKit dashboard виден активный publication у этого участника
- **Given** опубликованный трек **When** в той же комнате присутствует subscriber **Then** subscriber видит видео клиента с задержкой < 500 мс на одном LAN
- **Given** идёт стрим **When** прервать сеть на 5 сек и восстановить **Then** SDK переподключается автоматически (LiveKit reconnect), стрим продолжается
- **Given** идёт стрим **When** SDK теряет connection > 30 сек **Then** state переходит в `.error`, ошибка передаётся в delegate

**Артефакты:** `ios/CobrowseClient.swift`

**Зависимости:** P0-1, P0-2

**Оценка:** 2 дня

---

## P0-4 — Token server выдаёт JWT и хранит сессии

**Описание.** Node.js backend, который выдаёт publisher-токен клиенту и subscriber-токен агенту по коду.

**Acceptance criteria**

- **Given** запущенный token-server и Redis **When** `POST /session/create` с пустым body **Then** ответ содержит поля `code` (6 цифр в формате `XXX-XXX`), `roomName`, `livekitUrl`, `token`, `expiresIn`
- **Given** созданная сессия **When** проверить `redis-cli GET code:<code>` **Then** ключ существует с TTL ~600 сек
- **Given** код существует в Redis **When** `POST /agent/join` с этим кодом и agentId **Then** ответ содержит валидный JWT-токен с теми же `roomName` и `livekitUrl`, в Redis записывается `claimedByAgentId`, TTL кода продлевается до длительности сессии
- **Given** код уже заклаймлен agent'ом `A` **When** повторный `POST /agent/join` с тем же кодом и agentId `A` (StrictMode double-mount, F5, network retry) **Then** ответ `200` с валидным токеном (идемпотентно, LiveKit заменит участника по identity)
- **Given** код заклаймлен agent'ом `A` **When** `POST /agent/join` с этим же кодом но agentId `B` **Then** ответ `409 {"error":"code already claimed by another agent"}`
- **Given** недействительный код (123-456, которого нет в Redis) **When** `POST /agent/join` **Then** ответ `404`, в логи пишется warning
- **Given** > 30 запросов с одного IP за минуту **When** следующий запрос **Then** ответ `429 Too Many Requests`
- **Given** `POST /session/end` с валидным roomName **When** **Then** LiveKit `deleteRoom` вызван, в Redis статус сессии `ended`, room удалён из `sessions:active`

**Артефакты:** `backend/server.js`

**Зависимости:** P0-1

**Оценка:** 2 дня

---

## P0-5 — Session initiation через 6-значный код

**Описание.** Связать iOS SDK и web-agent через числовой код, который клиент диктует оператору.

**Acceptance criteria**

- **Given** iOS-приложение с SDK **When** вызвать `client.startSession()` **Then** SDK делает POST на `/session/create`, получает код, переводит state в `.streaming(code: "XXX-XXX")`
- **Given** state == `.streaming` или `.reconnecting` **When** прочитать `client.sessionCode` **Then** возвращается строка вида `"123-456"`
- **Given** агент в web-dashboard **When** ввести код и нажать "Подключиться" **Then** браузер делает POST на `/agent/join`, получает токен, подключается к LiveKit Room, видит видео клиента
- **Given** код не введён в течение 10 минут **When** агент пытается войти **Then** ответ `404`, агенту показывается «Код истёк»
- **Given** код 7 цифр или с буквами **When** агент пытается войти **Then** клиентская валидация блокирует запрос с сообщением «Код должен содержать 6 цифр»
- **Given** тот же agent (persistent agentId в sessionStorage) обновляет страницу viewer'а **When** viewer перезагружается с тем же кодом **Then** POST `/agent/join` возвращает токен (не 404), viewer переподключается к той же комнате

**Артефакты:** `backend/server.js`, `ios/CobrowseClient.swift`, `web-agent/app/page.tsx`

**Зависимости:** P0-3, P0-4

**Оценка:** 1 день

---

## P0-6 — Consent prompt на iOS

**Описание.** Перед стартом ReplayKit показать пользователю явное согласие. Без него запись не начинается.

**Acceptance criteria**

- **Given** state == `.idle` **When** вызвать `startSession()` **Then** state переходит в `.requestingConsent`, на экране появляется UIAlertController с текстом согласия
- **Given** пользователь нажал «Разрешить» **When** **Then** state переходит в `.connecting`, сессия запускается
- **Given** пользователь нажал «Отмена» **When** **Then** state возвращается в `.idle`, метод бросает `CobrowseError.consentDenied`, ReplayKit НЕ стартует
- **Given** в alert text упомянуто (буквально): что увидит оператор, что НЕ увидит (уведомления, банковские поля, другие приложения), возможность завершить в любой момент **When** показать UX-эксперту **Then** одобрение
- **Given** Android-related accessibility VoiceOver enabled **When** показывается alert **Then** текст полностью читается ассистивной технологией

**Артефакты:** `ios/ConsentPrompt.swift`

**Зависимости:** P0-2

**Оценка:** 0.5 дня (+ ревью текста с юристом — отдельно)

---

## P0-7 — Жизненный цикл сессии (start/stop с обеих сторон)

**Описание.** Корректное завершение сессии при инициативе клиента, агента, потере связи или таймауте.

**Acceptance criteria**

- **Given** активная сессия **When** клиент вызывает `stopSession()` **Then** SDK отключается от Room, дополнительно шлёт `POST /session/end` на backend (best-effort), state == `.ended`, агент в браузере получает событие `participantDisconnected` и UI показывает «Клиент завершил сессию», статус в списке сессий обновляется на `ended` в течение 5 сек
- **Given** активная сессия **When** агент нажимает «Завершить» в браузере **Then** браузер вызывает `POST /session/end`, backend делает `roomService.deleteRoom`, клиент получает `room disconnected` с reason `.serverClosed`, iOS SDK переходит в `.error("Оператор завершил сессию")` (не в `.ended`, чтобы отличать штатный стоп от закрытия оператором)
- **Given** активная сессия **When** клиент полностью убивает приложение **Then** LiveKit детектит disconnect (heartbeat fail), backend через 5 мин чистит запись сессии из Redis
- **Given** сессия началась **When** прошёл 1 час **Then** TTL JWT истёк, токен не обновляется, room закрывается, обе стороны получают disconnect
- **Given** сессия в `.ended` или `.error` **When** повторно вызвать `startSession()` **Then** создаётся новая сессия с новым кодом, без ошибок и без нужды в рестарте приложения (state machine restartable)
- **Given** идёт `.streaming` **When** сеть кратковременно отваливается **Then** state переходит в `.reconnecting(code)` (тот же код, та же комната), LiveKit auto-reconnect восстанавливает связь, state возвращается в `.streaming(code)` без явного действия пользователя
- **Given** идёт `.reconnecting` **When** сеть не восстановилась и LiveKit сдался **Then** state переходит в `.error("Соединение потеряно…")` (не в `.ended` — различаем сетевую потерю от штатного стопа)

**Артефакты:** `ios/CobrowseClient.swift`, `backend/server.js`, `web-agent/app/session/[code]/page.tsx`

**Зависимости:** P0-3, P0-4, P0-5

**Оценка:** 1 день

---

## P0-8 — Web-dashboard с list view и viewer

**Описание.** Web-страница для агентов: ввод кода + список ожидающих сессий + viewer.

**Acceptance criteria**

- **Given** агент открывает `https://agent.cobrowse.example.com` **When** **Then** виден input для кода и список активных сессий
- **Given** есть активные сессии в Redis **When** загрузить главную **Then** список содержит все сессии со статусом `waiting` или `active`, каждые 5 сек список обновляется
- **Given** агент нажимает «Войти» рядом с сессией **When** **Then** браузер переходит на `/session/<code>`, начинает подключение к LiveKit
- **Given** на странице сессии клиент уже стримит видео **When** loaded **Then** видео вписывается в `<video>` с `object-fit: contain` (letterbox), помещается целиком по ширине и по высоте — без скролла
- **Given** клиент ещё не начал стрим **When** loaded **Then** показывается один из гранулярных плейсхолдеров: "Клиент ещё не подключился", "Ждём публикации экрана", "Видео опубликовано, но не удалось подписаться" — в зависимости от того, где именно застряли
- **Given** на странице сессии **When** нажать «Завершить» **Then** вызывается `/session/end`, страница редиректит на `/`
- **Given** insecure origin (HTTP на LAN-IP) **When** открыть viewer **Then** сверху показывается баннер про getUserMedia limitation, LiveKitRoom подключается без auto-mic, видео работает, микрофон включается кнопкой в хедере
- **Given** секурный origin и mic-кнопка **When** нажать mic-кнопку **Then** getUserMedia запрашивает permission, при отказе кнопка становится красной с расшифровкой в tooltip, при согласии — зелёной, агента слышно у клиента

**Артефакты:** `web-agent/app/page.tsx`, `web-agent/app/session/[code]/page.tsx`

**Зависимости:** P0-4, P0-5

**Оценка:** 2 дня

---

## Итог по P0

| | |
|---|---|
| **Тикетов** | 8 |
| **Суммарная оценка** | 11.5 дней работы инженера |
| **Реалистичный календарный срок** | 3 недели (с учётом ревью, дебага сети, App Store device testing) |
| **Состав команды на P0** | 1 senior iOS + 1 senior backend (могут быть один full-stack человек, тогда 4 недели) + парт-тайм frontend |
| **DoD по всему P0** | iOS app → 6-значный код → агент в браузере видит экран клиента и слышит голос (если включил mic). Sub-500ms latency на одной локальной сети. |
