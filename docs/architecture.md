# Архитектурный обзор решения

Документ описывает архитектуру cobrowsing-решения, протестированного в рамках
Proof of Concept. Смежные документы: [тестовый стенд](test-stand.md),
[безопасность](security.md), [развёртывание](deployment.md).

## 1. Назначение и скоуп

**Задача:** оператор техподдержки видит экран iOS-приложения клиента в реальном
времени и голосом помогает пройти сценарий. Клиент явно даёт согласие и диктует
оператору короткий код сессии.

**Подход:** video-streaming cobrowsing — экран приложения захватывается через
ReplayKit (in-app capture, только своё приложение) и передаётся как WebRTC
видеопоток через self-hosted SFU (LiveKit) в браузер оператора. Референс —
Cobrowse.io.

**Скоуп PoC:** один VPS, одна ветка, без HA/staging/secret-manager. Цель —
подтвердить работоспособность связки iOS ReplayKit → WebRTC → SFU → браузер
на реальной инфраструктуре с TLS и реальными сетями (LTE, Wi-Fi, корпоративные).

## 2. Решение в двух абзацах

Клиент нажимает «Помощь оператора» в приложении, подтверждает согласие и
получает 6-значный код. SDK начинает публиковать видеопоток экрана в комнату
LiveKit. Клиент диктует код оператору (по телефону), оператор вводит его в
web-дашборде и подключается к той же комнате как подписчик. Двусторонний звук —
опционально, тем же WebRTC-соединением.

Вся инфраструктура self-hosted: LiveKit SFU (медиа), Node.js token-server
(JWT и жизненный цикл сессий), Redis (state), Next.js web-agent (интерфейс
оператора), Caddy (TLS-терминация). Никакие данные не проходят через сторонние
сервисы — это ключевое требование для enterprise-заказчиков (финсектор,
healthcare).

## 3. C4 Level 1 — System Context

```mermaid
C4Context
    title Cobrowsing PoC — System Context

    Person(customer, "Клиент", "Пользователь iOS-приложения, которому нужна помощь")
    Person(agent, "Оператор поддержки", "Помогает клиенту, видя его экран")

    System(cobrowse, "Cobrowsing-система", "Стриминг экрана iOS-приложения оператору в реальном времени. Self-hosted: LiveKit SFU + token-server + web-дашборд")

    System_Ext(hostapp, "iOS-приложение компании", "Приложение, в которое встроен Cobrowse SDK")
    System_Ext(phone, "Телефонный канал", "Существующая линия поддержки — клиент диктует код сессии")
    System_Ext(le, "Let's Encrypt", "Автоматическая выдача TLS-сертификатов (ACME)")

    Rel(customer, hostapp, "Использует, даёт согласие на шаринг экрана")
    Rel(hostapp, cobrowse, "Публикует видеопоток экрана, звук", "HTTPS + WebRTC")
    Rel(agent, cobrowse, "Смотрит экран клиента, говорит с ним", "HTTPS + WebRTC")
    Rel(customer, phone, "Диктует код сессии")
    Rel(phone, agent, "Передаёт код")
    Rel(cobrowse, le, "Получает и продлевает сертификаты", "ACME / HTTP-01")

    UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

Границы системы: cobrowsing-система не имеет собственной пользовательской базы
и аутентификации клиентов — она встраивается в существующее приложение и
существующий процесс поддержки. Единственная точка сопряжения с внешним миром —
код сессии, передаваемый по внеполосному каналу (телефон).

## 4. C4 Level 2 — Container

```mermaid
C4Container
    title Cobrowsing PoC — Containers

    Person(customer, "Клиент", "Пользователь iOS-приложения")
    Person(agent, "Оператор", "Сотрудник поддержки")

    Container_Boundary(ios, "iOS-приложение клиента") {
        Container(sdk, "Cobrowse SDK", "Swift, ReplayKit, LiveKit iOS SDK", "Consent-prompt, захват экрана (in-app), state machine сессии, публикация WebRTC-трека")
    }

    Container_Boundary(vps, "Self-hosted сервер (1 VPS, публичный IP)") {
        Container(caddy, "Caddy", "Caddy 2, host network", "TLS-терминация и reverse proxy для трёх доменов, авто-Let's Encrypt")
        Container(token, "Token-server", "Node.js, Express, :4000", "Создание сессий, генерация кодов, выдача JWT, завершение комнат")
        Container(livekit, "LiveKit SFU", "Go, host network, WS :7880, UDP 50000-60000, TCP fallback :7881", "WebRTC signaling и маршрутизация медиа (видео, звук, data)")
        Container(webagent, "Web-agent", "Next.js SSR, :3000", "Дашборд оператора: ввод кода, список сессий, viewer с диагностическим HUD")
        ContainerDb(redis, "Redis", "Redis 7, только 127.0.0.1", "Mapping код→комната (TTL 10 мин), state сессий (TTL 1 ч), room state LiveKit")
    }

    Container_Boundary(browser, "Браузер оператора") {
        Container(viewer, "Agent Viewer", "React, LiveKit JS SDK", "Подписка на видеопоток, mic toggle, диагностика соединения")
    }

    Rel(customer, sdk, "Запускает сессию, подтверждает согласие")
    Rel(agent, viewer, "Вводит код, смотрит экран")

    Rel(sdk, caddy, "POST /session/create", "HTTPS")
    Rel(viewer, caddy, "POST /agent/join, /session/list", "HTTPS")
    Rel(agent, caddy, "Открывает дашборд", "HTTPS")

    Rel(caddy, token, "api.* → :4000", "HTTP, localhost")
    Rel(caddy, webagent, "agent.* → :3000", "HTTP, localhost")
    Rel(caddy, livekit, "livekit.* → :7880", "WS upgrade, localhost")

    Rel(token, redis, "Коды, сессии", "RESP")
    Rel(token, livekit, "deleteRoom (RoomServiceClient)", "HTTP :7880")
    Rel(livekit, redis, "Room state", "RESP, 127.0.0.1")

    BiRel(sdk, livekit, "Медиа: видео + звук + data", "WebRTC/SRTP, UDP 50000-60000 или TCP 7881")
    BiRel(viewer, livekit, "Медиа", "WebRTC/SRTP")

    UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

Замечания к диаграмме:

- **Caddy и LiveKit работают в `network_mode: host`** — это осознанное решение,
  без которого UDP-медиа и cross-bridge маршрутизация на Ubuntu с ufw не
  работают надёжно. Backend и web-agent — в bridge-сети, наружу публикуются
  только на loopback (диагностика с самого VPS).
- **Медиа не проходит через Caddy.** TLS-терминация только для HTTP/WS
  (signaling и API). Медиапоток шифруется самим WebRTC (SRTP/DTLS) и идёт
  напрямую клиент ↔ LiveKit по UDP/TCP.
- **Три домена** (`livekit.*`, `api.*`, `agent.*`) обслуживаются одним Caddy
  на одном IP — разделение по hostname.

## 5. Жизненный цикл сессии

```mermaid
sequenceDiagram
    autonumber
    participant U as Клиент
    participant iOS as iOS SDK
    participant API as Token-server
    participant R as Redis
    participant LK as LiveKit
    participant Web as Agent Viewer
    participant A as Оператор

    U->>iOS: Нажимает «Помощь оператора»
    iOS->>U: Consent prompt
    U->>iOS: Подтверждает
    iOS->>API: POST /session/create
    API->>R: code:{code} (TTL 10 мин), session:{room} (TTL 1 ч)
    API-->>iOS: { code, livekitUrl, token (publisher JWT), roomName }
    iOS->>U: Показывает код «482-619»
    iOS->>LK: connect + publish video track (ReplayKit)
    Note over LK: Поток идёт, комната ждёт агента

    U->>A: Диктует код (телефон)
    A->>Web: Вводит код в дашборде
    Web->>API: POST /agent/join { code, agentId }
    API->>R: Проверка кода, claim за agentId (anti-hijack)
    API-->>Web: { livekitUrl, token (subscriber JWT), roomName }
    Web->>LK: connect
    LK->>Web: Видеопоток клиента

    Note over iOS,Web: Сессия активна: видео + звук + data

    A->>Web: End session
    Web->>API: POST /session/end
    API->>LK: RoomServiceClient.deleteRoom
    LK->>iOS: room disconnected
    iOS->>U: «Сессия завершена»
```

Свойства протокола, проверенные на стенде:

- `/agent/join` **идемпотентен** по паре (code, agentId): F5 в браузере, React
  StrictMode double-mount и сетевые ретраи не ломают сессию. Код, занятый
  другим агентом, возвращает 409.
- **iOS state machine restartable**: `idle → requestingConsent → connecting →
  streaming → ended/error`, из любого терминального состояния можно стартовать
  заново без перезапуска приложения. Авто-reconnect LiveKit отражается как
  `reconnecting(code)`.
- Завершить сессию может любая сторона; комната c пустым составом удаляется
  сервером через 5 минут (`empty_timeout`).

## 6. Ключевые архитектурные решения

### 6.1 Self-hosted LiveKit, а не managed-сервис

Полный контроль над данными (требование финсектора/healthcare), фиксированная
стоимость VPS вместо per-minute pricing, готовность к enterprise-запросу
«разверните в нашем VPC». Цена: сами отвечаем за эксплуатацию, мониторинг и
масштабирование. Миграция на LiveKit Cloud возможна без изменения клиентского
кода.

### 6.2 LiveKit, а не mediasoup/Janus/raw libwebrtc

Production-ready SDK для всех платформ, встроенная JWT-аутентификация,
server SDK для управления комнатами, Egress-сервис для будущей записи,
Apache 2.0. Это самый быстрый путь к работающему PoC.

### 6.3 Транспорт изолирован за протоколом `CobrowseTransport`

Единственный файл с `import LiveKit` — `ios/.../LiveKitTransport.swift`.
Бизнес-логика (`CobrowseClient.swift`) работает через транспорт-нейтральный
контракт. Смена транспорта (raw libwebrtc, mediasoup) — замена одного файла и
одной строки в `convenience init`. Это страховка от vendor lock-in на уровне
кода, дополняющая self-hosted подход на уровне инфраструктуры.

### 6.4 Video-streaming (ReplayKit), а не scene-graph

Захватываем пиксели экрана, а не дерево UI-элементов. Осознанный trade-off:

| | Video-streaming (наш выбор) | Scene-graph (Cobrowse.io) |
|---|---|---|
| Сложность реализации | Низкая — ReplayKit + WebRTC | Высокая — сериализация UI |
| Redaction (маскирование PII) | Сложно, пост-фактум по областям | Архитектурно встроено (private-by-default) |
| Bandwidth | Выше (видеокодек) | Ниже (диффы дерева) |
| Точность отображения | Пиксель-в-пиксель, включая WebView/канвас | Зависит от покрытия типов элементов |

Для PoC скорость реализации важнее. Redaction — главный известный долг подхода
(см. [security.md](security.md)).

### 6.5 TURN отключён

SFU на публичном IP + открытый UDP-диапазон + TCP fallback :7881 покрывают
~95% сетей. TURN нужен только для сетей «только TCP/443» и части CGNAT —
шаблон конфига закомментирован в `infra/livekit.yaml`, включение — 15 минут.

### 6.6 Host networking для LiveKit и Caddy

Docker bridge ломает WebRTC UDP (NAT внутри NAT) и cross-bridge маршрутизацию
при включённом ufw. LiveKit и Caddy работают в `network_mode: host`; Redis,
backend и web-agent — в bridge с публикацией только на 127.0.0.1.

### 6.7 Разделение LIVEKIT_URL / LIVEKIT_INTERNAL_URL

`LIVEKIT_URL` — адрес, который получают клиенты (wss через Caddy).
`LIVEKIT_INTERNAL_URL` — куда сам backend ходит за RoomServiceClient
(http://host.docker.internal:7880, минуя TLS-фронт). Оба задаются явно,
без «умных» fallback в коде.

### 6.8 Fail-fast конфигурация

Все env-переменные backend — обязательные, дефолтов в коде нет: сервер падает
на старте с «Missing env: X» вместо тихой работы со случайным значением.
Единый источник конфига — `.env` файл на стенде.

## 7. Ограничения PoC

Осознанно не реализовано (и не тестировалось): HA/мультинодовость, staging,
запись сессий (Egress), remote control (управление экраном клиента),
аннотации оператора поверх видео, redaction PII, RBAC операторов,
интеграция с CRM/helpdesk. Часть из этого — кандидаты на следующую итерацию,
оценка гэпов по безопасности — в [security.md](security.md).

## 8. Требования к ресурсам

| Масштаб | CPU | RAM | Канал |
|---|---|---|---|
| PoC (до 10 одновременных сессий) | 2 vCPU | 4 GB | 100 Мбит/с |
| Pilot (до 50 сессий) | 4 vCPU | 8 GB | 500 Мбит/с |
| Prod (100+ сессий) | 8+ vCPU, multi-node | 16+ GB | 1 Гбит/с+ |

Узкое место SFU — bandwidth, не CPU. Текущий стенд (Hetzner CX22: 2 vCPU/4 GB)
соответствует строке «PoC» — детали в [test-stand.md](test-stand.md).
