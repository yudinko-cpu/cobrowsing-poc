# Политики сторов и реальные внедрения in-app кобраузинга для поддержки

Исследование, сентябрь 2026. Аудитория — продукт, техлиды, ИБ. Проверяемая
гипотеза: «Google Play и App Store сильно режут приложения с кобраузинг-SDK
из-за пермишенов». Скоуп оценки — **только просмотр экрана host-приложения
из самого приложения** (как в PoC: без удалённого управления, без захвата
всего устройства). Full-device и remote control разобраны в одном разделе как
контраст, потому что именно они породили гипотезу.

Нумерация `[S#]` — ссылки на раздел 12 «Источники». Даты доступа: 11–14 сентября 2026.
Уровень доказательности отмечен там, где он не первичный: `[вторичный]`.

## TL;DR

**Гипотеза не подтверждается для in-app просмотра экрана host-приложения и
частично подтверждается для full-device / удалённого управления.**
Уверенность: высокая по текстам политик, средняя по практике ревью
(отсутствие найденных отказов — не доказательство их отсутствия).

1. **In-app захват собственного окна не требует ни одного OS-разрешения** ни на
   iOS (рендер view hierarchy), ни на Android (`View.draw` / `PixelCopy`). Ни у
   Apple, ни у Google, ни у RuStore нет правила, запрещающего эту технику. Все
   сторы регулируют её через согласие, индикацию и раскрытие: Apple 2.5.14
   [S1], Google User Data policy, где запись экрана прямо названа данными,
   требующими prominent disclosure [S43], RuStore — согласие «в форме активного
   действия» и статус оператора ПДн [S206].
2. **Единственный массовый enforcement за 8 лет — Apple, февраль 2019**
   (Glassbox/Appsee в Air Canada, Expedia, Hotels.com и др.): «раскрыть или
   удалить» за сутки. Наказали за отсутствие согласия и маскирования, а не за
   технику; вендоры той же техники работают до сих пор [S5][S6][S10].
   Удалений или отказов 2020–2026 по in-app захвату не найдено ни у Apple, ни у
   Google.
3. **Реальные внедрения в самых регулируемых вертикалях есть в обоих сторах:**
   Discovery Bank (Cobrowse.io, «Live Assist»), U.S. Bank и Elan Credit Card
   («Cobrowse» прямо в тексте карточки App Store), Klarna, Quicken, Tatra banka
   (Unblu), Intuit TurboTax (Glance SmartLook) [S123]–[S145]. У U.S. Bank
   кобраузингом пользовался «more than one in four» клиентов [S138].
4. **Та же техника массово стоит в сторах как session replay:** по AppBrain
   Sentry — «over 9 thousand» Android-приложений, Amplitude — «over 4
   thousand», Mixpanel — «over 3 thousand», Datadog — «over 1 thousand»,
   среди них ChatGPT, PayPal, Disney+, Duolingo [S105]–[S108]; UXCam заявляет
   «37,000+ products» и присутствует в Google Play SDK Index с единственным
   разрешением `WAKE_LOCK` [S54][S81].
5. **Где ограничения настоящие:** full-device (MediaProjection: согласие на
   каждую сессию, FGS-декларация с видео, антискам-пилоты Google с банками) и
   Accessibility-управление (Declaration Form + approval с ноября 2021) —
   вне нашего скоупа, хотя TeamViewer, AnyDesk и Cobrowse.io full-device
   продолжают жить в Play [S55][S58][S70][S71].
6. **Риски для PoC лежат рядом со сторами, а не в них:** (а) ReplayKit
   `startCapture` deprecated в iOS 27, замена — ScreenCaptureKit с системным
   пикером «только текущее приложение» и ключом `NSScreenCaptureUsageDescription`
   [S18][S21][S22]; (б) redaction обязательна де-факто (Air Canada 2019,
   черновик CNIL 2026) [S7][S111]; (в) правило Play «Respect the FLAG_SECURE
   setting» [S46]; (г) в РФ — антифрод банков детектирует системную трансляцию
   экрана и RAT, а с 01.03.2027 по 210-ФЗ банки обязаны отказывать в переводах
   при «вредоносном ПО»; ReplayKit-маршрут для такого антифрода неотличим от
   мошеннической демонстрации экрана [S213][S218].
7. **RU/СНГ:** единственное найденное внедрение — ВТБ для бизнеса (full-device,
   view-only, код доступа, опубликовано в RuStore) [S193]; локальные вендоры
   делают кобраузинг только для web; ниша свободна.
8. **Что делать в PoC:** согласие и REC-бейдж уже есть; добавить redaction API,
   `PrivacyInfo.xcprivacy`, план миграции с ReplayKit на рендер view hierarchy
   или ScreenCaptureKit, тексты disclosure и privacy labels для
   host-приложений, whitepaper для антифрод-команд банков, заметки для
   ревьюеров (§10).

## 1. Гипотеза и границы

| | В скоупе | Вне скоупа (только контраст, §4.6) |
|---|---|---|
| Что видит агент | Экран host-приложения | Весь экран устройства, другие приложения, уведомления |
| Управление | Нет (аннотации поверх) | In-app remote control; full-device control |
| iOS-механизмы | View hierarchy render; ReplayKit in-app (`RPScreenRecorder.startCapture`); ScreenCaptureKit `presentForCurrentApplication()` (iOS 27) | Broadcast Upload Extension; ScreenCaptureKit full display |
| Android-механизмы | `View.draw(Canvas)` / `PixelCopy` своего окна | MediaProjection; AccessibilityService; `SYSTEM_ALERT_WINDOW` |

Состояние PoC на момент исследования: iOS-only, захват через ReplayKit in-app
(`ios/CobrowseTestApp/sdk/ScaledScreenShareCapturer.swift`), consent-модалка до
захвата (`sdk/ConsentPrompt.swift`), REC-бейдж, 6-значный код сессии, без
redaction (`docs/security.md`), Android не реализован.

## 2. Техническая карта: что реально требует ОС

### 2.1 iOS

| Маршрут | Системный диалог | Индикатор ОС | Побочные эффекты | Статус API |
|---|---|---|---|---|
| Рендер view hierarchy (`drawHierarchy`, `CALayer.render`) — так работают Cobrowse.io, UXCam, FullStory, Datadog, Sentry и др. | Нет [S5][S83][S85] | Нет — индикатор обязан рисовать сам SDK (2.5.14) | Маскирование ломается на изменениях рендера ОС (Sentry отключал replay на iOS 26 с окт. 2025 по апр. 2026) [S89][S90] | Публичные API, без deprecation |
| ReplayKit in-app `RPScreenRecorder.startCapture` (текущий PoC) | Да: «ReplayKit presents a user consent alert requesting that the user acknowledge their intent to record the screen, the microphone, and the front camera» [S11]. Текст не кастомизируется; повторный показ «через 8 минут» подтверждён только форумами, на iOS 18.5+ есть сообщения о показе каждый раз `[вторичный]` [S12][S13] | Красный статус-бар для in-app режима Apple не документирует; DTS: захват без визуальной индикации невозможен [S14] | Записывает только своё приложение («record audio and video of your app»), один рекордер на устройство; уходит в фон — захват прерывается (`RPRecordingErrorCode.contentResize`) [S17][S19]. `UIScreen.isCaptured` = true при «recording, mirroring, or using AirPlay» — anti-capture логика банков может погасить и наш поток [S20] | **Deprecated в iOS 27** → «ScreenCaptureKit SCStream with SCStreamOutput» [S18]; экосистема уже ловит предупреждения (Zoom Video SDK, 2026-09-03) `[вторичный]` [S24] |
| ScreenCaptureKit (iOS 27+) | Да, системный пикер `SCContentSharingPicker`; `presentForCurrentApplication()` «Limits the picker to windows and layers owned by the running app only»; требуется `NSScreenCaptureUsageDescription` [S21][S22][S23] | Системный | «A broadcast extension is no longer necessary»; full display требует `UIBackgroundModes: screen-capture`; `SCShareableContent` на iOS недоступен — выбор только через пикер [S21][S22][S119] | Новый рекомендуемый путь |

### 2.2 Android (гипотетический порт)

| Маршрут | Разрешения | Системный диалог | Детект ОС | `FLAG_SECURE` |
|---|---|---|---|---|
| `View.draw(Canvas)` / `PixelCopy.request(window, …)` своего окна | Нет, кроме `INTERNET` (FullStory: только `INTERNET` и `ACCESS_NETWORK_STATE`; Cobrowse.io Android — требования только по API level) [S40][S83] | Нет | Не срабатывает: `addScreenRecordingCallback` (API 35) считает приложение записываемым, когда «activities owned by the registering process's UID are being recorded» системной записью; детект скриншотов Android 14 реагирует только на аппаратные кнопки [S64][S69] | Не блокирует in-process рендер: флаг «preventing it from appearing in screenshots or from being viewed on non-secure displays», `PixelCopy.java` не содержит обработки secure-окон; Android описывает флаг как защиту от скриншотов, каста и «remote screen sharing use cases» [S66]; Instabug получал жалобы, что его скриншоты игнорируют флаг [S65][S67][S68] `[вторичный]`. Политика Play: «Respect the FLAG_SECURE setting» → свои secure-экраны в поток не отдавать [S46] |
| MediaProjection (контраст) | `FOREGROUND_SERVICE_MEDIA_PROJECTION`, FGS type `mediaProjection` [S60] | Да, на каждую сессию с Android 14; выбор «одно приложение / весь экран» [S59][S61] | Android 15: чип в статус-баре, автостоп при блокировке, скрытие уведомлений/OTP/паролей [S62][S63] | Экран чёрный: «please make sure your views are not marked as secure» [S33] |
| AccessibilityService (контраст, управление) | `BIND_ACCESSIBILITY_SERVICE` + декларация в Play Console | Пользователь включает сервис в настройках | — | Play: «Don't transmit, save, or cache FLAG_SECURE protected content outside the device, even if an Accessibility Tool» [S46] |

Вывод раздела: в скоупе PoC единственный «пермишен» — системный consent-alert
ReplayKit (или пикер ScreenCaptureKit на iOS 27). Маршрут через рендер view
hierarchy вообще не касается системы разрешений, и именно на нём стоят все
индустриальные SDK.

## 3. Apple / App Store

### 3.1 Тексты правил

- **2.5.14** (помечено «ASR & NR» — действует и для App Store Review, и для
  нотаризации в ЕС): «Apps must request explicit user consent and provide a
  clear visual and/or audible indication when recording, logging, or otherwise
  making a record of user activity. This includes any use of the device camera,
  microphone, screen recordings, or other user inputs.» Это единственный пункт,
  где упомянуты «screen recordings» [S1].
- **История 2.5.14.** Пункт добавлен 4 июня 2018 в формулировке без «audible» и
  без «screen recordings» [S2][S3]; Apple цитировала его в этой редакции 7
  февраля 2019 [S6]; к 29 января 2024 текст уже содержал «screen recordings»
  [S4]. Точная дата вставки не найдена (§11).
- **5.1.1(i)** — политика конфиденциальности обязана назвать данные, способ
  сбора и «any third party with whom an app shares user data … such as analytics
  tools, advertising networks and third-party SDKs». **5.1.1(ii)** — «Apps that
  collect user or usage data must secure user consent for the collection, even
  if such data is considered to be anonymous»; нужен способ отозвать согласие.
  **5.1.1(iii)** — минимизация. **5.1.2(i)** — «you may not use, transmit, or
  share someone's personal data without first obtaining their permission»;
  нарушители «may be removed from sale». **5.1.2(ii)** — данные нельзя
  переиспользовать для другой цели без нового согласия [S1].
- **2.5.1** — только публичные API «for their intended purposes». Рендер view
  hierarchy, ReplayKit и ScreenCaptureKit — публичные [S1].

### 3.2 Поведение ReplayKit in-app (текущий маршрут PoC)

Сводка в §2.1. Дополнительно:

- Apple о фоне: «Allowing an app to record the entire screen even when it's in
  the background would pose serious privacy implications» (сотрудник Apple,
  2020) [S13].
- Ревью действительно прогоняет consent-flow: в 2019 приложение проваливало
  ревью из-за гонки consent-alert и старта ReplayKit [S16].
- Планка «индикатора» из реального отказа (камера, 2.5.14, 2024): «your app
  records video but does not have a clear visible visual indicator that the app
  is recording»; «the recording indicator cannot be disabled and your app cannot
  go blank during recording» [S15]. Для кобраузинга это означает: постоянный,
  неотключаемый бейдж на всё время сессии.

### 3.3 ScreenCaptureKit на iOS 27

«Use ScreenCaptureKit to capture high-performance video and audio across iOS,
iPadOS, macOS, tvOS, and visionOS»; «ScreenCaptureKit replaces ReplayKit for
screen streaming and mirroring. A broadcast extension is no longer necessary»;
«Request screen recording permission from the person before capturing content
… add a NSScreenCaptureUsageDescription key» [S21]. Статья «Capturing screen
content on iOS»: пикер даёт выбор «between capturing the entire display or
content from within the sample»; `present()` — весь дисплей,
`presentForCurrentApplication()` — только окна и слои текущего приложения; для
full display нужен фоновый режим `screen-capture` [S22]. Для PoC это означает
формализованный Apple in-app сценарий с системным согласием — то, что сейчас
делает ReplayKit, но без deprecation-риска.

### 3.4 Маршрут через view hierarchy: подтверждения вендоров

- TechCrunch о Glassbox: «Glassbox does not require any special permission from
  Apple or from the user, so there's no way a user would know» `[вторичный]` [S5].
- FullStory: «Session replay for mobile apps isn't a screen recording and
  Fullstory never captures screenshots from an end-user's device» [S83].
- Datadog: «takes a 'snapshot' of your app's screen by breaking it into simple
  rectangles called 'wireframes'» [S85].
- Smartlook: «Native rendering means Smartlook takes screenshots of the device
  screen and then composes the session recording» [S77].
- Microsoft Clarity: «Clarity for Mobile Apps does not capture screenshots or
  record of any user activity» (позиция вендора при заполнении privacy labels) [S96].
- UXCam (2026-05-28): «To ensure compliance with Apple privacy guidelines, we
  developed the Schematic Replay technology»; «UXCam should not interfere with
  your app submission and review process» [S80].
- Cobrowse.io (iOS 15+, «Our minimum supported iOS version is always the
  lowest Apple will accept as an App Store submission» [S39]; полный индекс
  документации [S122]): механизм захвата в документации не описан, но
  changelog говорит о
  «rendering method» («Switch to a faster rendering method», 2020; «Improved
  rendering method for iOS 26.0», 2025-09-18; «switch default render method to
  be more accurate and performant», 2025-11-11; «Introduce parallel
  compositor», 2026-09-07), есть plist-переключатель `CBIORenderMethod`, а
  ReplayKit упоминается только в контексте broadcast extension для full-device
  [S36][S37]. Consent: «By default, Cobrowse will show a user consent dialog
  when a new session is incoming», при этом «Admin users may also disable this
  consent prompt» [S32]. Redaction: «Anything that is redacted never leaves the
  users device and is never seen by the agent» [S35].

### 3.5 Раскрытие данных: labels, privacy manifest, подписи

- **App Privacy labels.** «Collect» = передача с устройства с доступом для вас
  или партнёров; разработчик обязан «identify all of the data you or your
  third-party partners collect». Подходящие категории: «Customer Support: Data
  generated by the user during a customer support request», «Product
  Interaction», «Other Usage Data», «Other User Content» [S25]. Прецеденты:
  Apple Support app декларирует «User Content (Customer Support)» [S30];
  FullStory и Smartlook рекомендуют «Product Interaction» + «Crash Data»
  [S84][S104]; Cobrowse.io в манифесте — «Customer Support» + «Device ID» [S37].
- **Privacy manifest (`PrivacyInfo.xcprivacy`).** Ключи `NSPrivacyTracking`,
  `NSPrivacyTrackingDomains`, `NSPrivacyCollectedDataTypes`,
  `NSPrivacyAccessedAPITypes`. Для SDK: обязателен, если SDK в списке Apple;
  иначе «include a privacy manifest file in your third-party SDK if it uses a
  required reasons API, collects data about the person using apps that include
  the third-party SDK…» — наш SDK подпадает [S26]. Сроки: с 1 мая 2024 —
  причины для required-reason API; с 12 февраля 2025 — валидные манифесты для
  SDK из списка; App Store Connect отклоняет невалидные манифесты [S27][S28].
- **Список «commonly used third-party SDKs»** (86 позиций): ни одного
  кобраузинг- или session-replay SDK — подпись обязательна только для списка,
  «we encourage all SDKs to adopt it» [S27][S29].
- Практика вендоров: Cobrowse.io добавил манифест 2024-04-15, Datadog 2024-01-25,
  PostHog 2024-02-23, UXCam 2024-03-14 [S37][S87][S94][S82].

### 3.6 Прецедент 2019: Glassbox / Appsee

- 6 февраля 2019, TechCrunch: Glassbox в Air Canada, Hollister, Abercrombie &
  Fitch, Expedia, Hotels.com, Singapore Airlines; Appsee и UXCam названы как
  конкуренты; в Air Canada маскирование отказало — «lets Air Canada employees …
  see unencrypted credit card and password information»; в политиках
  конфиденциальности — ни слова [S5][S7].
- 7 февраля 2019: Apple — «Protecting user privacy is paramount in the Apple
  ecosystem. Our App Store Review Guidelines require that apps request explicit
  user consent and provide a clear visual indication when recording, logging,
  or otherwise making a record of user activity»; письмо разработчикам: «Your
  app uses analytics software to collect and send user or device data to a
  third party without the user's consent»; меньше суток на удаление кода и
  повторную отправку, иначе удаление [S6][S8][S121].
- Последствия: Appsee куплен ServiceNow в мае 2019 и свёрнут [S9]; UXCam:
  «After talking to Apple, UXCam continues to work on both iOS and Android» и
  перешёл на схематичный replay [S10]. Какие именно приложения удалили SDK —
  не документировано (§11).
- Что важно для гипотезы: Apple потребовала согласие и раскрытие, а не запрет
  техники; та же техника в 2026 году стоит в тысячах приложений (§7).

### 3.7 Отказы и enforcement по захвату экрана, 2019–2026

| Год | Что | Причина | Исход | Применимо к in-app просмотру |
|---|---|---|---|---|
| 2019 | Glassbox/Appsee, десятки приложений | Нет согласия и индикации, PII без маски | «Раскрыть или удалить» за 24 ч [S6] | Да — ровно наши обязательства |
| 2019 | Приложение с ReplayKit in-app | Гонка consent-alert/старт записи | Провал ревью до фикса бага [S16] | Да — ревью прогоняет flow |
| 2024 | Приложение с записью камеры | Нет постоянного индикатора, экран мог гаснуть | Серия отказов по 2.5.14 [S15] | Да — планка индикатора |
| 2025 | Вопрос к DTS о захвате без индикации | — | «No» [S14] | Да |
| 2019–2026 | Policy-based отказы кобраузинг/session-replay SDK | — | Не найдены [S80][S31] | — |

### 3.8 Оценка риска (Apple)

Обязательства: явное согласие на каждую сессию с возможностью отозвать
(2.5.14, 5.1.1(ii)); постоянный неотключаемый индикатор без «гашения» экрана;
политика конфиденциальности host-приложения с именем SDK-вендора и сроками
хранения (5.1.1(i)); privacy labels host-приложения; `PrivacyInfo.xcprivacy` и
подписанный XCFramework у SDK; redaction на устройстве. Остаточные риски:
субъективность ревьюера по «clear indicator»; раскрытие «sharing with third
parties» по 5.1.2(i), если кадры идут через серверы вендора (self-hosted
снимает это); регрессии маскирования между релизами iOS.

**Вердикт:** Apple не «режет» согласованный, индицированный in-app кобраузинг.
Все найденные отказы и ответы Apple касаются отсутствия индикации, фона или
full-device. Уверенность ~80%.

## 4. Google Play / Android

### 4.1 User Data policy

- Триггер: prominent disclosure и consent нужны там, где «access, collection,
  use, or sharing of personal and sensitive user data may not be within the
  reasonable expectation of the user». Определение включает «other sensitive
  device or usage data» [S43].
- Требования к disclosure: «Must be within the app itself», «Must describe the
  data being accessed or collected», «Must explain how the data will be used
  and/or shared», «Cannot only be placed in a privacy policy». К consent: «Must
  require affirmative user action (for example, tap to accept, tick a
  check-box)», «Must be granted by the user before your app can begin to
  collect» [S43].
- **Запись экрана названа прямо** — как пример нарушения: «An app that records a
  user's screen and doesn't treat this data as personal or sensitive data
  subject to this policy» [S43]. То есть Play считает содержимое экрана
  чувствительными данными и регулирует, а не запрещает.
- SDK: «you must ensure that the third party code used in your app, and that
  third party's practices with respect to user data from your app, are
  compliant»; по запросу Google — «within 2 weeks … provide sufficient evidence
  demonstrating that your app meets the Prominent Disclosure and Consent
  requirements» [S43]. Best practices: «When the data collection is due to an
  SDK, clearly disclose the data involved, why the data is needed, and that it
  is shared with a third party»; «Give the user an option to decline» [S44].

### 4.2 Data safety

«'Collect' means transmitting data from your app off a user's device»; «'Sharing'
refers to transferring user data collected from your app to a third party».
Отдельного типа «screen recording» нет; «screenshots taken» — пример
метаданных в «App interactions». Поток экрана декларируется по содержимому:
«App activity → App interactions / Other actions», «Other user-generated
content», плюс всё, что может попасть в кадр (Personal info, Financial info)
[S45]. Исключение «ephemeral processing» — «accessing and using it while the
data is only stored in memory and retained for no longer than necessary to
service the specific request in real-time» — формально близко к live-стриму
без записи, но опираться на него для человеческого просмотра рискованно;
консервативно — декларировать [S45].

### 4.3 Остальные политики Play

- **Device and Network Abuse, «Flag Secure Requirements»:** «Respect the
  FLAG_SECURE setting»; «Don't bypass or create workarounds for FLAG_SECURE
  settings in other apps»; «Don't transmit, save, or cache FLAG_SECURE protected
  content outside the device, even if an Accessibility Tool» [S46]. Для SDK
  внутри банковского приложения: экраны, которые host сам пометил secure,
  считать redacted по умолчанию.
- **Malware / Stalkerware:** spyware — код, который «collects, exfiltrates, or
  shares user or device data that is not related to policy compliant
  functionality»; stalkerware — передача данных третьей стороне «for monitoring
  purposes» [S47]. Инициированный пользователем и раскрытый сеанс поддержки
  вне обоих определений.
- **Permissions and APIs:** только необходимые для текущих функций
  разрешения; про захват своего экрана — ничего [S48].
- **Financial Services:** запрет для loan-приложений на `READ_CONTACTS`,
  `READ_MEDIA_IMAGES`, `ACCESS_FINE_LOCATION` и др.; про захват экрана — ничего;
  обязательная Financial features declaration [S49].

### 4.4 SDK Console и SDK Index

Регистрация даёт вендору канал к разработчикам, ссылку на Data safety guidance,
бейдж «registered in Google Play SDK Console» и обязательство, что версии SDK
«will not cause apps to violate Google Play policies»; нарушения — отказ новых
версий приложений и снятие бейджа; ответственность всё равно на разработчике
приложения [S50][S51][S52][S53]. Пример: UXCam в Index — единственное
разрешение `WAKE_LOCK`, min API 21, по графику adoption — порядка тысяч
приложений с 1K–100K установок и единицы с 10M+; Cobrowse в Index не найден
(поиск «No SDKs») [S54].

### 4.5 Техника in-app на Android

Сводка в §2.2. Дополнительно: Sentry описывает свой Android-захват как
«redraw the screen contents onto a bitmap, masking all drawText and drawBitmap
operations» плюс стратегию `PixelCopy`; UXCam в changelog упоминает
«PixelCopy error log» [S91][S82]. Android 15 скрывает уведомления, OTP и
поля паролей только при MediaProjection-сессиях — для in-app потока никакой
системной защиты нет, redaction обязана быть своя [S63].

### 4.6 Контраст: full-device подходы и их ограничения (источник гипотезы)

| Механизм | Что требует Google | Даты | Живые примеры в Play |
|---|---|---|---|
| AccessibilityService (управление) | Ноябрь 2017: «Apps requesting accessibility services should only be used to help users with disabilities»; 30 дней на исправление (LastPass, Tasker, Greenify и др. в списке риска) `[вторичный]` [S57]. Июль 2021: «all apps that use the AccessibilityService API will need to disclose data access and purpose in Google Play Console and get approval» [S56]. Сейчас: Permission Declaration Form с 3 ноября 2021 для target Android 12+, `isAccessibilityTool` только для инструментов для людей с инвалидностью, остальным — prominent disclosure, запрет автономных действий [S55] | 2017, 2021 | TeamViewer QuickSupport + Universal Add-On, AnyDesk plugin ad1 остаются в Play с функциональным обоснованием [S74][S75][S76]; Cobrowse.io после смены политики выпустил 2.16.0 (2021-12-08): «Due to recent Google Play Store policy changes regarding use of the Accessibility Service APIs there are extra changes required» [S38] |
| MediaProjection (весь экран) | Согласие на каждую сессию (target 34), токен одноразовый, выбор «одно приложение/весь экран»; `FOREGROUND_SERVICE_MEDIA_PROJECTION` + декларация типа FGS в Play Console с видео [S58][S59][S60][S61][S117][S118] | Android 14, ноябрь 2023 | Cobrowse.io full-device: «You are required to fill in a declaration form on Google Play and provide a video» [S33] |
| Антискам 2025–2026 | 13 мая 2025: пилот «in-call protections for banking apps» в UK с Monzo, NatWest, Revolut; автоматический prompt остановить screen sharing по окончании звонка; блок выдачи accessibility во время звонка [S70]. 3 декабря 2025: расширение на «most major UK banks», пилоты в Бразилии и Индии, US-пилот с Cash App и JPMorganChase, 30-секундная пауза [S71]. 13 мая 2026: авто-сброс звонка по сигналу банка (Revolut, Itaú, Nubank) `[вторичный]` [S72] | 2025–2026 | Механизм детекта Google не раскрывает; системный сигнал записи существует только для MediaProjection (§2.2), поэтому in-app поток под него не подпадает — вывод по косвенным данным, уверенность средняя [S64][S73] |
| `SYSTEM_ALERT_WINDOW` | Только «направить в системные настройки» [S48] | — | Не нужен для аннотаций внутри своего приложения |

### 4.7 Оценка риска (Google Play)

Обязательства: in-app prominent disclosure до первого кадра с affirmative
opt-in и возможностью отказаться; Data safety — сбор (и «sharing», если вендор
не процессор) для App activity и всего, что видно на экране; политика
конфиденциальности с именем вендора; кадры = чувствительные данные;
хранить доказательства consent-flow (правило 2 недель); не стримить свои
`FLAG_SECURE`-экраны; redaction PIN/OTP/карт на устройстве.

**Вердикт:** для in-app просмотра Play не имеет ни политики, ни разрешения, ни
формы декларации, ни задокументированного enforcement — это упражнение по
disclosure/consent/Data safety. Уверенность: высокая по текстам, средняя по
практике. Для full-device и Accessibility — ограничения реальные, но
проходимые (TeamViewer, AnyDesk, Cobrowse.io full-device в сторе).

## 5. Сравнение уровней вторжения и политик

| Уровень | iOS: диалог ОС | iOS: политика | Android: диалог ОС | Android: политика/декларации | Гипотеза «режут» |
|---|---|---|---|---|---|
| In-app просмотр (скоуп) | Нет (render) / consent-alert (ReplayKit) / пикер (SCK) | 2.5.14, 5.1.1, 5.1.2, labels, manifest | Нет | User Data policy, Data safety, FLAG_SECURE respect | **Не подтверждается** |
| In-app remote control | Нет | те же + consent на управление (практика Cobrowse.io) [S37] | Нет | те же | Не подтверждается (вне скоупа, не исследовано глубоко) |
| Full-device просмотр | Broadcast picker / SCK full display | 2.5.14 + фоновый режим | MediaProjection consent на сессию | FGS-декларация с видео; Android 15 защиты; антискам-пилоты | **Частично подтверждается** |
| Full-device управление | Невозможно (Apple) [S34] | — | Включение AccessibilityService | Permission Declaration Form + approval; prominent disclosure | **Подтверждается** (высокое трение, но проходимо) |

## 6. Реальные внедрения (глобально)

Категория реальна и живёт в сторах, но **сконцентрирована**: нативные iOS/Android
SDK публикуют Cobrowse.io, Glance, Unblu, GoTo/LogMeIn Rescue, TeamViewer,
BeyondTrust, Zoho Assist, Upscope/UserView, Acquire, eGain. Публично
доказуемые production-приложения группируются вокруг Cobrowse.io, Glance и
Unblu. Большинство CCaaS/helpdesk-платформ (Genesys, NICE, Talkdesk, Twilio,
Zendesk, Intercom, Freshworks, ServiceNow) собственного in-app захвата не
имеют и работают через партнёров; собственный in-app screen share Salesforce
(SOS) сворачивается.

### 6.1 Вендоры с нативным mobile SDK

| Вендор | Техника на mobile (цитата) | Remote control | Замечания о сторах | Источник |
|---|---|---|---|---|
| Cobrowse.io | In-app: собственный рендер views; full device: Broadcast Extension / MediaProjection (§3.4, §4.6) | In-app + full-device на Android | PrivacyInfo, декларация FGS в Play для full-device; SOC 2 Type 2, ISO 27001, HIPAA, self-hosted [S42] | [S33][S34][S37] |
| Glance (Mobile App Sharing) | Публично не документирована; masking: «The SDK relies on the native view hierarchy to determine which views should be masked»; маркетинг: «You can mask sensitive information or entire screens from the representative's view» [S116] | Жесты/подсветка; «take limited control of the page» по одобрению клиента | Не найдено | [S150][S151][S152] |
| GoTo / LogMeIn Rescue (In-App Support SDK) | Android: «The contents of the embedder application's root view can be shared with the technician»; full device: «The SDK uses MediaProjection API to capture screen contents». iOS: «View the application screen», «Annotate the application screen» | Android in-app: root view «can be remotely controlled by the technician»; iOS — только просмотр/аннотации | Android target 29+: «you have to implement your own Service class and run as foreground service» | [S153][S154] |
| TeamViewer (Screen Sharing / Assist AR Mobile SDK) | iOS: «The UI of your application is grabbed using the ReplayKit» | «Remote Control (Android only)» | Декларация шифрования (CCATS) при загрузке в App Store | [S155][S156][S157] |
| BeyondTrust Remote Support SDK | «Application screen sharing» — «View your app on the remote device»; техника не описана | Не заявлено | «Apple does not allow an app to be submitted … if the app contains a framework that includes code for the x86_64 architecture». Собственный iOS-клиент убрал co-browse в 2018: «Removed co-browsing functionality from the app» | [S158][S159] |
| Unblu (Co-Apping, банки) | «Co-Apping works by capturing and transmitting structured mobile app elements (not the entire screen)» | «There's no remote control mode in mobile co-apping» | Consent-параметр `approveActivateMobile`; для screen share — «native OS-level permission dialog» | [S160][S161] |
| Salesforce | SOS (2014): «instantly share their mobile screen … an agent will see a mirror-image view and can draw on the screen» | Только рисование | «Salesforce is retiring the current SOS product offering»; «Salesforce will not be providing a migration solution» (2026-07-01). Visual Remote Assistant — камера/видео, не кобраузинг | [S162][S163][S164] |
| Zoho Assist SDK | «Share your screen directly from your customized mobile application»; техника не описана | Android, только OEM: «if it's a Samsung, Sony Xperia, or Lenovo device» | Не найдено | [S177][S178] |
| Upscope / UserView | По умолчанию «only your app's screen»; full device «via a ReplayKit Broadcast Upload Extension» | In-app: «Remote control (tap/scroll) only works within your app» | Broadcast picker «cannot be started programmatically» | [S179][S180] |
| Acquire.io | iOS SDK; маскирует «images, text fields, text views» | Неизвестно | Не найдено | [S183] |
| eGain | Заявлен кобраузинг в мобильных приложениях; техника не описана | Неизвестно | Не найдено | [S176] |
| Genesys / NICE CXone / Talkdesk / Twilio Flex / Zendesk / Intercom / Freshworks | Только web co-browse или партнёры: Genesys — «Co-browse for Web Messaging is fully supported in web and mobile web browsers» (2023); Talkdesk — «Cobrowse for Talkdesk provides seamless support across Web, Android, iOS, React Native, Xamarin…» (партнёр Cobrowse.io); Twilio — валидация Glance (2020) | Через партнёра | — | [S165]–[S174] |
| Fullview / Surfly / Samesurf | Нативные приложения не поддерживают (Fullview, 2026-04-10: «do not currently support native mobile apps»; Surfly: «through the use of a WebView only») | — | — | [S181][S182][S184] |
| LivePerson / Verint | Mobile co-browse SDK не найден | — | — | [S175] |

### 6.2 Подтверждённые production-приложения

| Приложение | Компания / страна | SDK | Платформы | Доказательство | Стор |
|---|---|---|---|---|---|
| Discovery Bank («Live Assist») | Discovery Bank, ЮАР | Cobrowse.io | iOS, Android | Кейс: «deployed Cobrowse into the mobile banking app and branded it internally as 'Live Assist'»; новость банка (2021-05-13): «Our Discovery Bankers can only see your banking app screens» [S123][S124] | App Store (v7.4.0): «Get support 24/7/365 with features like Live Assist…» [S125]; Play [S126] |
| Klarna | Klarna Bank AB | Cobrowse.io | iOS, Android | Кейс: «a solution that was stable in Native, iOS and Android, not just web»; «+75,000 sessions per month»; «We ask for consent to use co-browsing and we've updated our terms and conditions» [S127] | App Store [S128] (в описании не упомянуто) |
| Quicken Classic / Simplifi | Quicken Inc. | Cobrowse.io | iOS, Android, web | Кейс: «the ability to use Cobrowse on a mobile was hugely beneficial»; «40,000+ sessions per month» [S129] | App Store [S130] |
| ShiftMed | ShiftMed | Cobrowse.io | iOS, Android (гибрид) | Кейс: «The Cobrowse SDKs provide support across iOS and Android hybrid apps» [S131] | App Store [S132] |
| Lightspeed POS | Lightspeed Commerce | Cobrowse.io | iOS, web | Кейс: «visibility across iOS, web and mobile»; «3,000–4,000+ Cobrowse sessions per month» [S133] | App Store [S134] (какое из трёх POS-приложений — не подтверждено) |
| Elan Credit Card | Elan Financial Services, США | «Cobrowse» (вендор не назван) | iOS, Android | Release note v25.11.3 (2025-11-19) в App Store: «Cobrowse enables real-time, privacy-protected screen sharing so agents can assist customers directly within the mobile app» [S135] | App Store [S135]; Play [S136] |
| U.S. Bank Mobile Banking | U.S. Bancorp, США | «Cobrowse» (вендор не назван) | iOS, Android | Описание в App Store: «get real-time support with Cobrowse»; пресс-релиз (2023-04-06): «More than one in four U.S. Bank customers have now used cobrowse», «on both mobile app and online banking» [S137][S138] | App Store [S137]; Play [S139] |
| TurboTax (SmartLook / TurboTax Live) | Intuit, США | Glance | iOS, Android | Glance (2021-02-26): «Glance provides the technology that powers Intuit's acclaimed SmartLook™ in-app support functionality»; PR 2018-05-24, CIO Intuit: «to deliver exceptional customer care to users of our native mobile apps»; Intuit community (2019): SmartLook доступен «TurboTax Online or our mobile app» [S140][S141][S142] | App Store id619342115 (текст карточки инструментами не прочитан) |
| Tatra banka («Podpora na diaľku») | Tatra banka, Словакия | Unblu Co-Apping | iOS, Android | Пресс-релиз банка (2025-07-14): «využíva technológiu od švajčiarskej firmy Unblu»; «ako prvá banka v regióne implementovala službu priamo do mobilnej aplikácie»; кейс Unblu [S143][S144] | App Store [S145] |
| Xfinity Mobile Care | Assurant для Xfinity, США | Не назван | iOS | App Store (v4.57.0): «Connect with tech experts via chat, call, screen share, or camera share» [S146] | App Store [S146] |
| Google Support Services (Pixel) | Google | First-party | Android | Play: «the agent will not be able to control your device, but will be able see your screen»; «cannot be started by itself and is used only when a Google customer support agent sends an invite» [S147] | Play-листинг при проверке недоступен (404); текст из поискового индекса — не подтверждено [S147] |
| Amazon Mayday (2013–2018, история) | Amazon | First-party (Fire OS) | Fire OS | PR 2013-09-25: советник «can co-pilot you through any feature by drawing on your screen… or doing it for you»; закрыт в июне 2018 `[вторичный]` [S148][S149] | — |

Дополнительно: Axos Bank использовал Glance только в web (2019) и лишь
планировал добавить в приложение [S189]; Cobrowse.io заявляет «Over 50 global
enterprises run their own instance of Cobrowse» [S190]; Unblu пишет о
безымянном «major European bank … 2,200 advisors» [S192] (не подтверждено, §11).

Что важно для гипотезы: **пять банковских приложений (Discovery Bank, U.S.
Bank, Elan, Tatra banka, Klarna) и TurboTax живут в App Store и Google Play с
in-app кобраузингом**, причём U.S. Bank и Elan упоминают функцию прямо в
тексте карточки, и ни у одного нет следов проблем с ревью.

### 6.3 Поиск по описаниям в сторах

Запросы `site:apps.apple.com "share your screen" support`, `"cobrowse"`,
`"co-browse"`, `site:play.google.com "screen share" "support agent"` и ещё ~10
вариантов дали лишь пять встроенных внедрений (Elan, U.S. Bank, Discovery Bank,
Xfinity Mobile Care, Google Support Services). Klarna, Quicken и Apple Support
о функции в карточке молчат [S128][S130][S30]. Вывод: текст карточки — слабый
детектор, большинство интеграций в листингах не видны. Остальные хиты —
клиентские приложения вендоров, которые агент просит установить (GoToAssist
Customer, LogMeIn Resolve, Zoho Assist Customer, ScreenMeet, Fullview) [S191].

### 6.4 First-party прецеденты платформ

- **Apple Support:** вход через ara.apple.com («Share your screen»); по словам
  сообщества, «Sharing tool Apple uses is built into iOS, no installation of
  other software is needed», советники «can only view the screen … cannot
  control it» `[вторичный]` [S185][S186]. Отдельно iOS 26 добавил обмен экраном
  и удалённое управление в приложении «Телефон» между пользователями [S187].
- **Samsung Remote Service:** «remotely view and control your Samsung
  smartphone or tablet», согласие на каждое приложение [S188]. Full device с
  управлением на правах OEM.
- **Google Support Services (Pixel):** предустановлено, только просмотр,
  запуск по инвайту агента [S147]. Листинг в Play при проверке отдаёт 404 —
  данные не подтверждены первичным источником (§11).
- **Amazon Mayday:** 2013–2018, рисование на экране и управление силами OEM [S148][S149].

### 6.5 Заявления вендоров о сторах и отказах

Ни один вендор не документирует отказ App Store/Play. Единственный публичный
«откат» — BeyondTrust убрал co-browse из собственного iOS-клиента в 2018 без
объяснения причин [S159]. Замечания вендоров касаются рутины: декларация
шифрования (TeamViewer) [S157], foreground service при target 29+ (Rescue)
[S154], запрет x86_64-кода в фреймворке (BeyondTrust) [S158], системный пикер
для full device, который «cannot be started programmatically» (UserView)
[S180]. Klarna о собственной практике: «We ask for consent to use co-browsing
and we've updated our terms and conditions» [S127].

### 6.6 Выводы по разделу

- Внедрения есть и в самых регулируемых вертикалях (банки, налоги), в обоих
  сторах, с 2018 года по сегодня — гипотеза «режут» для in-app просмотра
  опровергается практикой.
- Рынок концентрирован вокруг специализированных вендоров; платформенные
  игроки (Salesforce SOS) выходят из ниши, а не расширяются в ней — это
  сигнал о сложности продукта, а не о запретах сторов.
- Ни один вендор не публикует гайд «как пройти ревью» — обязательства сводятся
  к согласию, индикатору и privacy-декларациям, которые вендоры считают
  очевидными.
- Рынок это подтверждает: отчёт Cobrowse.io за 2025 год фиксирует «growing gap
  between web and mobile adoption» — мобильный кобраузинг отстаёт от web из-за
  сложности внедрения, а не из-за сторов [S115]. Определение категории у того
  же вендора: «co-browsing solutions only let agents see the windows or apps
  the customer chooses, not everything on their device» [S41].

## 7. Session replay как массовый прецедент той же техники

Session-replay SDK захватывают экран собственного приложения тем же способом,
что и in-app кобраузинг, только пассивно и с записью. Это самый большой
корпус доказательств, что сторы не блокируют технику.

### 7.1 Техника и маскирование

| SDK | iOS | Android | Диалог ОС | Маскирование по умолчанию | Источник |
|---|---|---|---|---|---|
| Smartlook | «Regularly captures the app screen which the SDK immediately processes to remove sensitive data»; wireframe-режим без данных | те же режимы | нет | EditText/WebView в blacklist; продукт сворачивается после сделки с Cisco: «30 September 2027 – Platform Decommissioned» | [S77][S78] |
| UXCam | Schematic replay «without recording the app's screen» по умолчанию; опционально реальный UI | видео-режим | нет | пароли, номера карт, OTP скрыты по умолчанию | [S79][S80] |
| FullStory | «based on drawing operations, where text, images, and personal data are masked at the source by default» | то же | нет | Private-by-Default | [S83] |
| Datadog RUM | wireframes, 64–100 мс | то же | нет; `trackingConsent` | «mask is enabled by default» | [S85][S86] |
| Sentry | view hierarchy + скриншот раз в секунду, свой CoreGraphics-рендер | `PixelCopy` или Canvas-стратегия | нет | «masks all text content, images, webviews, and user input» | [S88][S91] |
| PostHog | view hierarchy → JSON wireframe | то же | нет | `maskAllTextInputs`/`maskAllImages` = true | [S93] |
| Microsoft Clarity | «capturing low-level drawing commands» | то же | нет; consent API | `maskView` | [S95] |
| Contentsquare | view hierarchy; «All iOS views … fully masked by default» | пикселизация; всё замаскировано | нет; consent — предварительное условие | mask-all | [S97][S98] |
| Mixpanel | «capturing UI hierarchy changes and storing them as images» | то же | нет | inputs всегда, текст/изображения/WebView по умолчанию | [S99] |
| Amplitude | «captures changes to an app's view tree» | то же | нет | Medium: «Masks all editable text views» | [S100] |
| Instabug (Luciq) | скриншоты при смене экрана | то же | нет | WebView по умолчанию, private views — чёрный оверлей | [S101] |
| Pendo | захват экранов/тапов, «Privacy rules are applied on the device at the moment of capture» | то же | нет | пресеты «Maximum Privacy» | [S102] |
| Bugsee | «Pixel-accurate replay», adaptive fps | то же | нет | secure/password поля скрыты, private views не покидают устройство | [S103] |

Ни один вендор не упоминает разрешение ОС для iOS/Android; единственный
iOS-маршрут с системным диалогом — ReplayKit — никто из них не использует
(NowSecure, 2019) `[вторичный]` [S110].

### 7.2 Масштаб

| SDK | AppBrain, Android (11.09.2026) | Названные приложения (AppBrain) | Заявления вендора |
|---|---|---|---|
| Sentry | «Over 9 thousand» приложений; 3,94% приложений; 14,89% top-apps | ChatGPT, Duolingo, Canva, Discord, PUBG MOBILE, Claude, Firefox | — |
| Amplitude | «Over 4 thousand»; 1,63% | Nu, Domino's, AJIO, YouVersion | — |
| Mixpanel | «Over 3 thousand»; 1,21% | Aadhaar, Viber, ZEE5, Bolt, Grok AI | — |
| Datadog | «Over 1 thousand»; 0,66%; 13,83% top-apps | ChatGPT, X, Disney+, Claude, PayPal, Grab, Indeed, Domino's | — |
| UXCam | не отслеживается AppBrain; есть в Google Play SDK Index | — | «Installed in 37,000+ products» [S81] |
| Appsee (закрыт 2019) | 0,03% приложений — остаточное присутствие | — | — |

Источники: [S105][S106][S107][S108][S109][S54]. Оговорка: AppBrain считает
присутствие SDK целиком (crash/analytics + replay); доля приложений с
включённым replay неизвестна.

### 7.3 Опубликованные гайды по соответствию сторам

| Вендор | Privacy manifest | Labels / Data safety | Согласие |
|---|---|---|---|
| Datadog | с 2.7.0 (2024-01-25) [S87] | — | «Mobile RUM tracking is only run upon user consent»; `trackingConsent` [S86] |
| Sentry | с 8.25.0: CrashData, PerformanceData, OtherDiagnosticData, App Functionality [S92] | — | самоотключение на iOS 26 «to prevent PII leaks» [S89] |
| UXCam | 3.6.11 (2024-03-14) [S82] | — | 2019: «To comply with the new Apple guideline, we are making multiple product changes» [S10] |
| Smartlook | не найден | «Product Interaction ✓», «Crash Data ✓», «Other Diagnostic Data ✓» [S104] | open-source consent SDK |
| FullStory | не найден | «Product Interaction ✓», «Crash Data ✓», «not linked to the user's identity» [S84] | — |
| Contentsquare | «it is up to you to update the privacy practices … in your app manifest» [S97] | Android: «update your Google Play Data Safety declaration accordingly» [S98] | «The users have given their consent (if required)» [S97] |
| Clarity | не найден | App Store privacy guidance: Product Interaction — да, Customer Support — нет [S96] | «You're responsible for obtaining the user's consent» [S95] |

Ни одна страница вендоров не ссылается на 2.5.14 по номеру и не заявляет
«одобрено App Store»; ближайшее — UXCam 2019 и 2026 [S10][S80].

### 7.4 Инциденты после 2019

- Store-enforcement 2020–2026 по session replay/кобраузингу: не найдено ни у
  Apple, ни у Google.
- Саморегуляция вендоров: Sentry 8.57.0 (окт. 2025) — «Session Replay is
  disabled by default on iOS 26.0+ with Xcode 26.0+ to prevent PII leaks» из-за
  Liquid Glass; включён обратно в 9.12.0 (апр. 2026) [S89][S90]; PostHog
  3.36.1 (2025-12-16) «fix: SwiftUI view masking on iOS 26» [S94]; UXCam
  3.10.0 (2026-07-30) — фикс occlusion на iOS 26 [S82]. Паттерн: смена
  рендера ОС молча ломает маскирование сразу у нескольких вендоров.
- Регуляторы: CNIL, 25 февраля 2026 — проект рекомендации по session replay
  для «website or mobile application operators»: «Prior consent is therefore
  the rule», пароли и платёжные данные «blocked by default», предпочтительна
  выборочная/триггерная запись [S111][S112] `[вторичный по деталям]`.
- Судебные иски (CIPA/wiretap) — только web-сайты; дел по мобильным
  приложениям с replay-SDK не найдено [S113][S114].

### 7.5 Что это значит для кобраузинга

Тот же механизм и та же рулбук: 2.5.14 + prominent disclosure + manifest +
labels + маскирование по умолчанию. Кобраузинг выгодно отличается: сессия
инициируется пользователем, согласие и индикатор естественны, записи нет.
Но живой человек на другой стороне поднимает планку маскирования (Air
Canada, CNIL). Вывод: класс SDK сторы не блокируют — уверенность ~90%.

## 8. RU/СНГ

Поиск шёл по русскоязычным справкам банков, телекомов и маркетплейсов,
карточкам в App Store / Google Play / RuStore, новостям и документации
локальных вендоров (~45 запросов, ~40 страниц). Ниша в РФ/СНГ почти пуста,
а ограничения лежат в антифроде, а не в сторах.

### 8.1 Приложения с демонстрацией экрана поддержке

| Приложение | Компания | Что есть | Доказательство | Стор |
|---|---|---|---|---|
| Бизнес Платформа ВТБ (Android) / Бизнес Импульс (iOS) | Банк ВТБ, сегмент СМБ | Только просмотр; запуск из чата поддержки; код доступа; **весь экран устройства** (системный уровень) | kdelu.vtb.ru, 21.06.2024: «ВТБ реализовал возможность демонстрации экрана во время звонка в техподдержку»; «Шаринг запускается через раздел «Чат»… выбрать пункт «Демонстрация экрана»»; «Система предложит Вам установку кода доступа, который оператор Банка введёт у себя в программе»; «Во время демонстрации экрана совершать активные действия может только сам клиент»; «на платформе Android на время шаринга оператору будут видны системные уведомления»; «В приложении «Бизнес Импульс» на платформе IOS во время демонстрации экрана показ оповещений блокируется» [S193] | RuStore [S194]; карточка iOS-версии в App Store при проверке 14.09.2026 недоступна (404) [S195] |
| Т-Банк, СберБанк Онлайн, Альфа-Банк, ВТБ Онлайн (розница), Райффайзен, Газпромбанк, Ozon Банк, Почта Банк, Совкомбанк, Яндекс Go/Пэй, Ozon, Wildberries, Мой МТС, Билайн, МегаФон, t2, Ростелеком | — | Функция «показать экран оператору» не найдена; телеком-чаты предлагают прикрепить скриншот | Не найдено | — |
| Kaspi.kz, Halyk, Freedom, monobank, Privat24, Kapital Bank | — | Не найдено. Обратный пример: Kaspi блокирует захват экрана: «На Android нельзя сделать скриншот»; «При записи экрана появится уведомление «Выключите запись экрана»» (17.08.2026) [S196] | — | — |

Кейс ВТБ важен вдвойне: это банковское приложение с full-device screen share,
опубликованное в RuStore (iOS-версия в App Store на момент проверки
недоступна), — то есть даже более инвазивный, чем наш, сценарий локальный
стор пропускает.

### 8.2 Локальные вендоры

| Вендор | Co-browsing | Mobile SDK с захватом экрана | Цитата |
|---|---|---|---|
| Webim | Да, только web (DOM-уровень) | Нет: Mobile SDK — чат [S197] | TAdviser (2015): «Оператор видит, какую страницу сайта просматривает посетитель и что он ввёл в формы» `[вторичный]` [S198] |
| edna | Не найдено | Чат-SDK без захвата экрана [S199] | — |
| LiveTex | Заявлен «Кобраузинг» в карточке Startpack `[вторичный]` [S200]; на livetex.ru не найден | Mobile SDK 2.x — чат/файлы [S201] | — |
| Naumen Contact Center | Заявлена «демонстрация экрана» в чате сайта и мобильного приложения | Техника не описана | «Чат на сайте и в мобильном приложении: … запуск демонстрации экрана» [S202] |
| Voximplant (CPaaS) | Screen share в звонке, не кобраузинг | Да, iOS/Android | «Screen sharing for Android is based on Android's MediaProjection API»; iOS: «you can share only the screen of your application… if you build a banking application, and you need to share the client's screen for support purposes» [S203] |
| Usedesk | Да, web | Нет | «провести клиента за руку по вашему сайту: помочь заполнить форму заявки» [S204] |
| VideoForce | «Шеринг экрана» в видеочате для сайта | Нет | «видеочат для сайта», установка «через код виджета» [S205] |
| Jivo, Omnidesk, Chat2Desk, Carrot quest, MTS Exolve, Sherpa, Mango Office, UIS | Не найдено | Не найдено | — |
| Западные SDK (Cobrowse.io, Glance, Unblu, TeamViewer) в РФ/КЗ | Внедрений не найдено | — | — |

### 8.3 RuStore и AppGallery

- **RuStore, «Гайд по требованиям к приложениям»** [S206]: ПДн — «если
  приложение подразумевает работу с персональными данными, убедитесь, что у
  вас есть официальный статус оператора персональных данных»; «Вы также
  должны уведомить пользователя о том, что его данные собираются, и получить
  его согласие на их обработку». Разрешения — «Если при загрузке в RuStore
  Консоль в приложении будут обнаружены запрещенные разрешения, данная версия
  будет отклонена»; «обнаружатся чувствительные разрешения, разработчику
  следует обосновать использование каждого»; «согласие пользователя на
  предоставление разрешения предоставлено в форме активного действия».
  Норм про захват экрана, MediaProjection или accessibility нет; страница
  «Типы разрешений» отдавала HTTP 429 — список запрещённых разрешений не
  проверен (§11) [S207]. Вторичный обзор причин отклонения: «сбор личных
  данных без согласия пользователей», обязательная политика
  конфиденциальности «прямо в приложении» [S208].
- **Huawei AppGallery Review Guidelines §7** (14.01.2026) [S209]: 7.9
  «collection and use must comply with the principle of minimization»; 7.10
  «must not collect and use personal data in a secretive manner»; 7.8
  «explicit consent for processing of sensitive personal data»; 7.18 «clear
  description about the functions and scenarios that request permissions».
  Про захват экрана — ничего.

Вывод: локальные сторы регулируют то же, что Apple и Google, — согласие,
раскрытие, минимизацию, — плюс 152-ФЗ-специфику (статус оператора ПДн).

### 8.4 Антифрод-контекст

- **Банк России:** предупреждения о схеме «включить демонстрацию экрана»
  (31.08.2022) [S210]; в признаках мошеннических операций (11.07.2024)
  демонстрация экрана не упомянута [S211]; с 01.01.2026 новый признак —
  обнаружение на устройстве за 48 часов до перевода «вредоносного программного
  обеспечения, изменения операционной системы или провайдера связи» [S212].
- **210-ФЗ от 26.06.2026** [S213][S214]: оператор по переводу «при наличии
  информации о воздействии вредоносного программного обеспечения отказывает в
  приеме к исполнению»; банки обязаны применять «средства защиты информации,
  прошедшие … процедуру оценки соответствия». РБК (08.08.2026): «Российские
  банки с 1 марта 2027 года будут отказывать клиентам в переводах с устройств,
  на которых выявили вредоносное ПО» `[вторичный]` [S215]; трактовки:
  сертифицированные модули ФСТЭК/ФСБ в приложениях, проверка «активные сессии
  удаленного доступа» `[вторичный]` [S216][S217].
- **Т-Банк** (12.08.2024): «защитные технологии, которые проверяют телефон на
  наличие программ удаленного доступа»; «система реагирует, если на смартфоне
  включена демонстрация экрана или кто-то управляет устройством дистанционно»;
  реакция — усиленный мониторинг переводов, не блокировка приложения [S218].
  Побочный эффект: Google Play Protect пометил приложение Т-Банка —
  «Приложение является подозрительным и собирает данные, которые могут
  использоваться для слежки» (Хабр, 13.01.2025) `[вторичный]` [S219]. Это
  редкий пример, когда антифрод-код сам попал под подозрение платформы.
- **Сбер:** встроенный антивирус на Android, «блокирует финансовые операции в
  реальном времени» `[вторичный]` [S220][S221]; схема «видеозвонок +
  трансляция экрана» описана Сбером и МВД (03.2024) `[вторичный]` [S222][S223].
- **ВТБ (розница):** предупреждения о RAT-приложениях `[вторичный]` [S224];
  детекция в самом приложении не подтверждена (§11).
- **СНГ:** Kaspi блокирует скриншоты и запись экрана [S196]; Halyk: «Работники
  Банка не предлагают устанавливать сторонние мобильные и веб-приложения»
  [S225]; ПриватБанк — только про пароли/CVV [S226].

Что из этого следует для in-app SDK: банки детектируют (а) установленные
RAT-приложения, (б) системный факт трансляции экрана (Android MediaProjection,
iOS `isCaptured`), (в) accessibility и оверлеи, (г) с 2027 — «вредоносное ПО»
сертифицированными модулями. SDK, который рендерит собственную view-иерархию
без MediaProjection/ReplayKit/accessibility, системные флаги (а)–(в) не
поднимает. Остаточный риск — эвристики сертифицированных модулей и
антивируса Сбера могут счесть «передачу изображения экрана на сервер»
подозрительной; внутри чужого банковского приложения SDK окажется под его же
антифродом. Отдельно: ReplayKit-маршрут PoC выставляет `isCaptured` и на
Android-аналоге поднимал бы MediaProjection — то есть выглядел бы для
антифрода host-приложения ровно как мошенническая демонстрация экрана. Это
ещё один аргумент за рендер view hierarchy.

### 8.5 Выводы по RU/СНГ

- Подтверждённое внедрение одно — ВТБ для бизнеса, full-device, view-only, с
  кодом доступа; розничных банков, маркетплейсов и телекомов с «показать экран
  оператору» не найдено. Ниша свободна.
- Локальные вендоры делают кобраузинг только для web; единственные мобильные
  варианты — заявление Naumen без описания техники и CPaaS Voximplant с
  MediaProjection/in-app share.
- Реальные ограничения: RuStore/AppGallery — про ПДн и раскрытие, не про
  захват; антифрод банков и 210-ФЗ — про RAT и системную трансляцию экрана;
  Kaspi-подобные защиты блокируют MediaProjection/запись, но не in-app рендер.
- Для SDK: не использовать MediaProjection/ReplayKit-broadcast/accessibility/
  overlay; consent + индикатор + код сессии (как у ВТБ); маскирование ПДн;
  хранение в РФ и договор с host как оператором ПДн; документ для
  антифрод-команд host-банков и сертифицированных модулей: «это не RAT — нет
  ввода, нет чужих окон, нет системного захвата».

## 9. Прецеденты санкций и ограничений: сводная таблица

| Год | Платформа | Кто / что | Что нарушено или введено | Чем кончилось | Затрагивает in-app просмотр? |
|---|---|---|---|---|---|
| 2017-11 | Google Play | Приложения с AccessibilityService не для инвалидности (LastPass, Tasker, Greenify…) `[вторичный]` [S57] | Accessibility только для людей с инвалидностью | 30 дней на исправление; позднее смягчено, в 2021 заменено декларацией [S56] | Нет |
| 2018-06 | App Store | Введён 2.5.14 [S2][S3] | Согласие + индикация при записи активности | Действует, расширен на «screen recordings» [S1][S4] | Да — базовое обязательство |
| 2019-02 | App Store | Glassbox/Appsee: Air Canada, Expedia, Hotels.com, Hollister, A&F, Singapore Airlines [S5] | Без согласия, без индикации, PII без маски | «Раскрыть или удалить» за 24 ч; Appsee закрыт; UXCam сменил технику [S6][S9][S10] | Да — те же обязательства |
| 2021-11 | Google Play | Все приложения с AccessibilityService (target 12+) [S55] | Permission Declaration Form + approval | Действует; TeamViewer/AnyDesk остаются [S74][S75] | Нет |
| 2023-05 | Google Play | Loan-приложения [S49] | Запрет ряда разрешений | Действует | Нет |
| 2023-11 → 2024 | Google Play | FGS types, в т.ч. `mediaProjection` [S58][S60] | Декларация с видео при target 34 | Действует | Нет (только full-device) |
| 2024-05 / 2025-02 | App Store | Privacy manifests, required reasons, подписи SDK [S27][S28] | Отказ невалидных манифестов | Действует | Да — SDK обязан поставлять манифест |
| 2024 | App Store | Приложение с записью камеры [S15] | 2.5.14: нет неотключаемого индикатора | Серия отказов | Да — планка индикатора |
| 2025-05 → 2026-05 | Android/Play | Антискам-пилоты с банками (UK, BR, IN, US) [S70][S71][S72] | Screen sharing во время звонка + банковское приложение | Prompt/пауза/сброс звонка | Нет (MediaProjection) |
| 2025-10 → 2026-04 | Вендор | Sentry отключает replay на iOS 26 [S89][S90] | Риск утечки PII из-за нового рендера | Полгода без функции | Да — риск маскирования |
| 2026-02 | CNIL (EU) | Проект рекомендации по session replay [S111] | Предварительное согласие, блок паролей/платежей | Консультации | Да — для EU-хостов |
| 2025-01 | Google Play Protect | Приложение Т-Банка `[вторичный]` [S219] | Антифрод-детект RAT/screen share принят за слежку | Предупреждение Play Protect | Косвенно — любой код, «похожий на слежку», под подозрением |
| 2026-06 → 2027-03 | РФ, 210-ФЗ | Все банки [S213][S215] | Отказ в переводах при «вредоносном ПО», сертифицированные модули защиты | Вступает в силу 01.03.2027 | Да — SDK должен быть «читаем» для антифрода |

## 10. Чек-лист соответствия и что доделать в PoC

### 10.1 SDK (наша сторона)

- [ ] `PrivacyInfo.xcprivacy` в XCFramework: `NSPrivacyTracking=false`, типы
  «Customer Support» (+ «Device ID», если есть идентификатор устройства), цели
  «App Functionality», required-reason API, если используются (UserDefaults,
  file timestamps) [S26][S37]. Подпись XCFramework — рекомендация Apple [S27].
- [ ] Consent-flow, который нельзя обойти конфигом (в отличие от Cobrowse.io, где
  админ может отключить диалог [S32]) — иначе host рискует по 2.5.14 и User Data policy.
- [ ] Постоянный неотключаемый индикатор на всё время сессии; экран не должен
  «гаснуть» [S15]. В PoC REC-бейдж есть (`ContentView.swift`), но живёт в
  демо-приложении, а не в SDK — перенести в SDK-слой.
- [ ] Redaction API (делегат/модификатор SwiftUI/селекторы) + режим
  «private by default»; secure text fields, поля карт/OTP скрывать без участия
  разработчика; всё маскирование — на устройстве до кодирования кадра
  [S35][S79][S86]. Для ReplayKit-маршрута это архитектурно сложно
  (пиксели уже сняты) — аргумент в пользу рендера view hierarchy или SCK с
  пост-обработкой по геометрии view.
- [ ] Android: `View.draw`/`PixelCopy` своего окна, ни одного разрешения кроме
  `INTERNET`; уважать `FLAG_SECURE` собственных экранов [S46]; не тянуть
  storage/media-разрешения (loan-apps) [S49].
- [ ] Миграция iOS-захвата: ReplayKit `startCapture` deprecated в iOS 27 →
  ScreenCaptureKit `SCContentSharingPicker.presentForCurrentApplication()` +
  `NSScreenCaptureUsageDescription`; для iOS < 27 оставить ReplayKit или
  перейти на рендер view hierarchy [S18][S21][S22].
- [ ] Обработать `UIScreen.isCaptured` / `sceneCaptureState`: host-приложения
  банков гасят экран при захвате — SDK должен уметь сообщить host, что захват
  «свой» [S20].
- [ ] Kill-switch и gating по версиям ОС для маскирования (урок Sentry/iOS 26) [S89].
- [ ] Регистрация в Google Play SDK Console + Data safety guidance для хостов [S50][S52].
- [ ] Комплект для host-команд: тексты disclosure (RU/EN), рекомендуемые
  privacy labels и Data safety-строки, абзац для политики конфиденциальности,
  заметки для App Review с демо consent-flow.

### 10.2 Host-приложение (что мы должны требовать/рекомендовать)

- App Store: политика конфиденциальности с именем SDK и сроками хранения
  (5.1.1(i)); labels «Customer Support»/«Other Usage Data»; при облачном
  вендоре — раскрытие «shared with third parties» (5.1.2(i)) [S1][S25].
- Google Play: in-app prominent disclosure до первого кадра, affirmative
  consent, возможность отказа [S43][S44]; Data safety: App activity (+ всё, что
  видно на экране), шифрование в транзите, удаление; для финансовых приложений —
  Financial features declaration [S45][S49].
- Заметки для ревьюеров обоих сторов: как вызвать сессию, где согласие, где
  индикатор, что маскируется.

### 10.3 RuStore

- Статус оператора ПДн у host (или договор поручения обработки с вендором
  SDK); уведомление и согласие «в форме активного действия»; политика
  конфиденциальности прямо в приложении [S206][S208].
- Обоснование каждого чувствительного разрешения в RuStore Консоль — для
  in-app маршрута их нет; список запрещённых разрешений сверить, когда
  страница «Типы разрешений» станет доступна [S207].
- AppGallery: описание сценариев запроса разрешений (7.18), минимизация,
  явное согласие на чувствительные ПДн (7.8) [S209].
- Хранение и обработка кадров в РФ (152-ФЗ) — self-hosted-архитектура PoC
  это закрывает.
- Для host-банков: согласовать с антифрод-командой и поставщиками
  сертифицированных модулей (210-ФЗ), что SDK не является RAT: нет ввода,
  нет захвата чужих окон, нет MediaProjection/accessibility; подготовить
  технический whitepaper [S213][S218].

## 11. Открытые вопросы

- Точная дата, когда в 2.5.14 добавили «and/or audible» и «screen recordings»
  (между 2019-02-07 и 2024-01-29) [S4][S6].
- Показывает ли in-app `startCapture` красный статус-бар и выставляет ли
  `UIScreen.isCaptured` — Apple не документирует; проверить на устройстве в
  PoC (быстрый тест на iOS 26 и бета iOS 27). Есть сообщение, что на iOS 26.2
  `isCaptured` становится false при продолжающейся системной записи —
  семантика уходит на уровень сцены [S120].
- Текущая частота повторного consent-alert ReplayKit (форумы: 8 минут; iOS 18.5+
  — каждый раз) [S12][S13].
- Механизм screen sharing в Apple Support app (системный или broadcast
  extension) и точный детект «screen sharing» в антискам-пилотах Google.
- Как классифицировать live-стрим без записи в Data safety: «ephemeral
  processing» или сбор — нужна позиция юристов; рекомендация — декларировать.
- Какие именно клиенты Glassbox удалили SDK в 2019.
- Cobrowse.io: механизм in-app захвата на iOS/Android документально не описан
  (по косвенным данным — собственный рендер view hierarchy).

- RuStore: список запрещённых и чувствительных разрешений (страница отдавала
  HTTP 429) [S207].
- Детектирует ли «ВТБ Онлайн» (розница) удалённый доступ и демонстрацию
  экрана в самом приложении — только нечитаемые отзывы.
- Текст 41-ФЗ от 01.04.2025 (ГИС «Антифрод») в части удалённого доступа —
  первоисточник не извлечён.
- Дата «1 сентября 2026» для защиты приложений по 210-ФЗ противоречива между
  источниками; надёжная дата — 01.03.2027 [S213][S215].
- Есть ли кобраузинг у LiveTex и Usedesk в мобильных SDK — только карточки и
  закрытые страницы документации.
- Использование Cobrowse.io / Glance / Unblu в РФ/КЗ — не найдено ни одного
  упоминания.
- Вендор «Cobrowse» у U.S. Bank и Elan не назван; принадлежность SDK
  Lightspeed конкретному POS-приложению; безымянные банки в кейсах Glance и
  Unblu [S137][S135][S133][S192].
- Google Support Services (Pixel): листинг в Play недоступен (404);
  подтвердить существование и описание функции другим первичным источником [S147].
- Канал распространения iOS-версии «Бизнес Импульс» ВТБ: карточка в App Store
  отдаёт 404 [S195].

## 12. Источники

Первичные источники (Apple, Google, Android/iOS SDK docs, вендорские доки, сторы, репозитории) помечены `[P]`, вторичные (пресса, форумы, блоги) — `[S]`. Даты доступа: 11–14.09.2026.

- [S1] [P] Apple, App Store Review Guidelines — https://developer.apple.com/app-store/review/guidelines/
- [S2] [S] App Store Review Guidelines History, изменения 2018-06-04 — https://www.appstorereviewguidelineshistory.com/articles/2018-06-04-wwdc2018/
- [S3] [P] Apple Developer News, 2018-06-04 — https://developer.apple.com/news/?id=06042018a
- [S4] [S] App Store Review Guidelines History, редакция 2024-01-29 — https://www.appstorereviewguidelineshistory.com/articles/2024-01-29-notarization-in-european-union/
- [S5] [S] TechCrunch, 2019-02-06, «Many popular iPhone apps secretly record your screen without asking» — https://techcrunch.com/2019/02/06/iphone-session-replay-screenshots/
- [S6] [S] TechCrunch, 2019-02-07, «Apple tells app developers to disclose or remove screen recording code» — https://techcrunch.com/2019/02/07/apple-glassbox-apps/
- [S7] [S] The App Analyst, разбор Air Canada — https://theappanalyst.com/aircanada.html
- [S8] [S] MacRumors, 2019-02-07 — https://www.macrumors.com/2019/02/07/apple-makes-devs-remove-screen-recording-code/
- [S9] [S] TechCrunch, 2019-05-13, ServiceNow acqui-hires Appsee — https://techcrunch.com/2019/05/13/servicenow-acquihires-mobile-analytics-startup-appsee/
- [S10] [P] UXCam blog, 2019-02-10, «Important update regarding the new App Store compliance guidelines» — https://uxcam.com/blog/important-update-regarding-the-new-app-store-compliance-guidelines/
- [S11] [P] Apple Platform Security, ReplayKit consent, 2021-02-18 — https://support.apple.com/guide/security/seca5fc039dd/web
- [S12] [S] Apple Developer Forums, thread 88189 (2017, повтор alert через 8 минут) — https://developer.apple.com/forums/thread/88189
- [S13] [S] Apple Developer Forums, thread 651099 (2020/2025, фон и частота prompt) — https://developer.apple.com/forums/thread/651099
- [S14] [S] Apple Developer Forums, thread 774107 (DTS, 2025-02) — https://developer.apple.com/forums/thread/774107
- [S15] [S] Apple Developer Forums, thread 654120 (отказ по 2.5.14, 2024-08) — https://developer.apple.com/forums/thread/654120
- [S16] [S] Apple Developer Forums, thread 109696 (ReplayKit и ревью, 2019) — https://developer.apple.com/forums/thread/109696
- [S17] [P] Apple, RPScreenRecorder — https://developer.apple.com/documentation/replaykit/rpscreenrecorder
- [S18] [P] Apple, startCapture(handler:completionHandler:) — https://developer.apple.com/documentation/replaykit/rpscreenrecorder/startcapture(handler:completionhandler:)
- [S19] [P] Apple, RPRecordingErrorCode — https://developer.apple.com/documentation/replaykit/rprecordingerrorcode
- [S20] [P] Apple, UIScreen.isCaptured — https://developer.apple.com/documentation/uikit/uiscreen/iscaptured
- [S21] [P] Apple, ScreenCaptureKit — https://developer.apple.com/documentation/screencapturekit
- [S22] [P] Apple, «Capturing screen content on iOS» — https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios
- [S23] [P] Apple, SCContentSharingPicker — https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker
- [S24] [S] Zoom Developer Forum, 2026-09-03, ReplayKit deprecation warnings в Xcode 27 — https://devforum.zoom.us/t/zoomvideosdk-emits-deprecation-warnings-around-replaykit-in-xcode-27/146197
- [S25] [P] Apple, App privacy details on the App Store — https://developer.apple.com/app-store/app-privacy-details/
- [S26] [P] Apple, Privacy manifest files — https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- [S27] [P] Apple Developer News, 2024-02-29, privacy manifest deadlines — https://developer.apple.com/news/?id=3d8a9yyh
- [S28] [P] Apple, Adding a privacy manifest to your app or third-party SDK — https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk
- [S29] [P] Apple, Upcoming third-party SDK requirements (список SDK) — https://developer.apple.com/support/third-party-SDK-requirements/
- [S30] [P] App Store, Apple Support (privacy label) — https://apps.apple.com/us/app/apple-support/id1130498044
- [S31] [P] App Store, Cobrowse.io demo app — https://apps.apple.com/in/app/cobrowse-io/id6479618392
- [S32] [P] Cobrowse.io docs, User consent dialog — https://docs.cobrowse.io/sdk-features/customize-the-interface/user-consent-dialog
- [S33] [P] Cobrowse.io docs, Full device screen sharing — https://docs.cobrowse.io/sdk-features/full-device-capabilities/full-device-screen-sharing
- [S34] [P] Cobrowse.io docs, Full device remote control — https://docs.cobrowse.io/sdk-features/full-device-capabilities/full-device-remote-control
- [S35] [P] Cobrowse.io docs, Redact sensitive data — https://docs.cobrowse.io/sdk-features/redact-sensitive-data
- [S36] [P] Cobrowse.io docs, Alternate render method (iOS) — https://docs.cobrowse.io/sdk-features/advanced-features/ios/alternate-render-method
- [S37] [P] GitHub, cobrowseio/cobrowse-sdk-ios-binary (CHANGELOG, PrivacyInfo.xcprivacy, заголовки) — https://github.com/cobrowseio/cobrowse-sdk-ios-binary
- [S38] [P] GitHub, cobrowseio/cobrowse-sdk-android-binary, CHANGELOG — https://github.com/cobrowseio/cobrowse-sdk-android-binary/blob/master/CHANGELOG.md
- [S39] [P] Cobrowse.io docs, iOS installation — https://docs.cobrowse.io/sdk-installation/ios
- [S40] [P] Cobrowse.io docs, Android installation — https://docs.cobrowse.io/sdk-installation/android
- [S41] [P] Cobrowse.io, «What is co-browsing?» — https://cobrowse.io/articles/what-is-co-browsing
- [S42] [P] Cobrowse.io, Security — https://cobrowse.io/security
- [S43] [P] Google Play, User Data policy — https://support.google.com/googleplay/android-developer/answer/10144311
- [S44] [P] Google Play, Prominent disclosure best practices — https://support.google.com/googleplay/android-developer/answer/11150561
- [S45] [P] Google Play, Data safety section — https://support.google.com/googleplay/android-developer/answer/10787469
- [S46] [P] Google Play, Device and Network Abuse — https://support.google.com/googleplay/android-developer/answer/9888379
- [S47] [P] Google Play, Malware policy — https://support.google.com/googleplay/android-developer/answer/9888380
- [S48] [P] Google Play, Permissions and APIs that Access Sensitive Information — https://support.google.com/googleplay/android-developer/answer/16558241
- [S49] [P] Google Play, Financial Services policy — https://support.google.com/googleplay/android-developer/answer/9876821
- [S50] [P] Google Play, SDK Index — https://support.google.com/googleplay/android-developer/answer/12034434
- [S51] [P] Google Play, SDK policy issues — https://support.google.com/googleplay/android-developer/answer/14514531
- [S52] [P] Google Play, SDK Console registration — https://support.google.com/googleplay/android-developer/answer/12244916
- [S53] [P] Google Play, Using SDKs safely — https://support.google.com/googleplay/android-developer/answer/13326895
- [S54] [P] Google Play SDK Index, UXCam — https://play.google.com/sdks/details/com-uxcam-uxcam
- [S55] [P] Google Play, AccessibilityService API policy — https://support.google.com/googleplay/android-developer/answer/10964491
- [S56] [P] Android Developers Blog, 2021-07-28, policy updates — https://android-developers.googleblog.com/2021/07/announcing-policy-updates-to-bolster.html
- [S57] [S] Android Police, 2017-11-12, Accessibility crackdown — https://www.androidpolice.com/2017/11/12/google-will-remove-play-store-apps-use-accessibility-services-anything-except-helping-disabled-users/
- [S58] [P] Google Play, Foreground service and full-screen intent requirements — https://support.google.com/googleplay/android-developer/answer/13392821
- [S59] [P] Android 14 behavior changes (MediaProjection consent) — https://developer.android.com/about/versions/14/behavior-changes-14
- [S60] [P] Android 14, Foreground service types are required — https://developer.android.com/about/versions/14/changes/fgs-types-required
- [S61] [P] Android 14, App screen sharing — https://developer.android.com/about/versions/14/features/app-screen-sharing
- [S62] [P] Android 15 features (screen recording detection, MediaProjection chip) — https://developer.android.com/about/versions/15/features
- [S63] [P] Android 15 behavior changes (sensitive content protection) — https://developer.android.com/about/versions/15/behavior-changes-all
- [S64] [P] Android, WindowManager.addScreenRecordingCallback — https://developer.android.com/reference/android/view/WindowManager
- [S65] [P] Android, WindowManager.LayoutParams.FLAG_SECURE — https://developer.android.com/reference/android/view/WindowManager.LayoutParams#FLAG_SECURE
- [S66] [P] Android, Fraud prevention: activities and FLAG_SECURE — https://developer.android.com/security/fraud-prevention/activities
- [S67] [P] AOSP, PixelCopy.java — https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/main/graphics/java/android/view/PixelCopy.java
- [S68] [S] GitHub, Instabug-Android issue 368 «Honor FLAG_SECURE», 2021-03-19 — https://github.com/Instabug/Instabug-Android/issues/368
- [S69] [P] Android 14, Screenshot detection — https://developer.android.com/about/versions/14/features/screenshot-detection
- [S70] [P] Google, 2025-05-13, «What's new in Android security and privacy in 2025» — https://blog.google/security/whats-new-in-android-security-privacy-2025/
- [S71] [P] Google, 2025-12-03, Android expands in-call scam protection — https://blog.google/security/android-expands-pilot-in-call-scam-protection-financial-apps/
- [S72] [S] Android Police, 2026-05-13, авто-сброс звонков — https://www.androidpolice.com/android-will-start-ending-calls-automatically-to-protect-you-from-scams/
- [S73] [S] Guardsquare, 2024-10-29, Android 15 screen spying protection — https://www.guardsquare.com/blog/android-15-screen-spying-protection
- [S74] [P] TeamViewer KB, Universal Add-On for Android — https://www.teamviewer.com/en/global/support/knowledge-base/teamviewer-classic/mobile/android/universal-add-on-for-android/
- [S75] [P] AnyDesk KB, Android — https://support.anydesk.com/knowledge/android
- [S76] [P] Google Play, TeamViewer QuickSupport — https://play.google.com/store/apps/details?id=com.teamviewer.quicksupport.market
- [S77] [P] Smartlook docs, Rendering modes — https://mobile.developer.smartlook.com/docs/rendering-modes
- [S78] [P] Smartlook, Mobile app analytics (уведомление о сворачивании) — http://www.smartlook.com/mobile-app-analytics/
- [S79] [P] UXCam Help, Schematic replay — https://help.uxcam.com/en/articles/10222760-schematic-replay
- [S80] [P] UXCam Help, Apple's privacy guidelines, 2026-05-28 — https://help.uxcam.com/hc/en-us/articles/4403226273933-Apple-s-privacy-guidelines
- [S81] [P] UXCam, Session replay («37,000+ products») — https://uxcam.com/experience-analytics/session-replay/
- [S82] [P] UXCam, iOS changelog — https://developer.uxcam.com/docs/ios-changelog
- [S83] [P] FullStory Help, Intro to Fullstory for Mobile Apps — https://help.fullstory.com/hc/en-us/articles/4414642861463-Intro-to-Fullstory-for-Mobile-Apps
- [S84] [P] FullStory Help, Apple Questionnaire — https://help.fullstory.com/hc/en-us/articles/1500000353921-Fullstory-for-Mobile-Apps-Privacy-Settings-Apple-Questionnaire
- [S85] [P] Datadog docs, Mobile Session Replay — https://docs.datadoghq.com/session_replay/mobile/
- [S86] [P] Datadog docs, Mobile Session Replay privacy options — https://docs.datadoghq.com/session_replay/mobile/privacy_options/
- [S87] [P] Datadog, dd-sdk-ios CHANGELOG — https://raw.githubusercontent.com/DataDog/dd-sdk-ios/master/CHANGELOG.md
- [S88] [P] Sentry docs, Session Replay for Mobile — https://docs.sentry.io/product/explore/session-replay/mobile
- [S89] [P] Sentry Cocoa 8.57.0 release notes — https://github.com/getsentry/sentry-cocoa/releases/tag/8.57.0
- [S90] [P] Sentry Cocoa 9.12.0 release notes — https://github.com/getsentry/sentry-cocoa/releases/tag/9.12.0
- [S91] [P] Sentry docs, Android Session Replay — https://docs.sentry.io/platforms/android/session-replay/
- [S92] [P] Sentry docs, Apple privacy manifest — https://docs.sentry.io/platforms/apple/guides/ios/data-management/apple-privacy-manifest/
- [S93] [P] PostHog docs, Mobile session replay — https://posthog.com/docs/session-replay/mobile
- [S94] [P] PostHog, posthog-ios CHANGELOG — https://raw.githubusercontent.com/PostHog/posthog-ios/main/CHANGELOG.md
- [S95] [P] Microsoft Learn, Clarity Mobile SDK overview — https://learn.microsoft.com/en-us/clarity/mobile-sdk/mobile-sdk-overview
- [S96] [P] Microsoft Learn, Clarity App Store privacy guidance — https://learn.microsoft.com/en-us/clarity/mobile-sdk/sdk-apple-appstore-privacy-guidance
- [S97] [P] Contentsquare docs, iOS Session Replay — https://docs.contentsquare.com/en/csq-sdk-ios/experience-analytics/session-replay/
- [S98] [P] Contentsquare docs, Android Session Replay — https://docs.contentsquare.com/en/csq-sdk-android/experience-analytics/session-replay/
- [S99] [P] Mixpanel docs, Session Replay iOS — https://docs.mixpanel.com/docs/session-replay/implement-session-replay/session-replay-ios
- [S100] [P] Amplitude docs, Session Replay iOS plugin — https://amplitude.com/docs/sdks/session-replay/session-replay-ios-plugin
- [S101] [P] Luciq (Instabug) docs, iOS Session Replay — https://docs.luciq.ai/docs/ios-session-replay
- [S102] [P] Pendo Help, Session Replay privacy — https://support.pendo.io/hc/en-us/articles/18049064847515-Session-Replay-privacy
- [S103] [P] Bugsee docs, iOS video privacy — https://docs.bugsee.com/sdk/ios/privacy/video/
- [S104] [P] Smartlook docs, Apple privacy questionnaire — https://mobile.developer.smartlook.com/reference/apple-privacy-questionnaire
- [S105] [S] AppBrain, Sentry library stats — https://www.appbrain.com/stats/libraries/details/sentry/sentry
- [S106] [S] AppBrain, Datadog library stats — https://www.appbrain.com/stats/libraries/details/datadog/datadog
- [S107] [S] AppBrain, Amplitude library stats — https://www.appbrain.com/stats/libraries/details/amplitude/amplitude
- [S108] [S] AppBrain, Mixpanel library stats — https://www.appbrain.com/stats/libraries/details/mixpanel/mixpanel
- [S109] [S] AppBrain, Android analytics libraries — https://www.appbrain.com/stats/libraries/tag/analytics/android-analytics-libraries
- [S110] [S] NowSecure, 2019-02-18, Mobile app session replay & its privacy impact — https://www.nowsecure.com/blog/2019/02/18/mobile-app-session-replay-its-privacy-impact/
- [S111] [P] CNIL, 2026-02-25, public consultation on session replay — https://www.cnil.fr/en/session-replay-cnil-launches-public-consultation-its-draft-recommendation
- [S112] [S] Clifford Chance, 2026-03-06, Session replay tools under scrutiny — https://www.cliffordchance.com/insights/resources/blogs/talking-tech/en/articles/2026/03/session-replay-tools-under-scrutiny--cnil-launches-public-consul.html
- [S113] [S] Inside Class Actions, 2026-01-27, website wiretapping roundup — https://www.insideclassactions.com/2026/01/27/2025-website-wiretapping-roundup/
- [S114] [P] US Court of Appeals, 3rd Cir., Hasson v. FullStory, 2024-09-05 — https://www2.ca3.uscourts.gov/opinarch/232535p.pdf
- [S115] [P] Cobrowse.io, 2025 Cobrowsing Market Data Report — https://cobrowse.io/publications/2025-cobrowsing-market-data-report
- [S116] [P] Glance, Mobile App Share — https://www.glance.cx/guided-cx-platform/mobile-app-share
- [S117] [P] Android, MediaProjection guide — https://developer.android.com/media/grow/media-projection
- [S118] [P] Android, Foreground service types — https://developer.android.com/develop/background-work/services/fgs/service-types
- [S119] [P] Apple, SCShareableContent — https://developer.apple.com/documentation/screencapturekit/scshareablecontent
- [S120] [S] Apple Developer Forums, thread 817446 (isCaptured на iOS 26.2, 2026-03) — https://origin-devforums.apple.com/forums/thread/817446
- [S121] [S] Gummicube, 2019-02-12, Session replay technology leads to App Store removals — https://www.gummicube.com/blog/session-replay-technology-leads-to-app-store-removals/
- [S122] [P] Cobrowse.io docs, полный индекс — https://docs.cobrowse.io/llms.txt
- [S123] [P] Cobrowse.io, кейс Discovery Bank — https://cobrowse.io/case-studies/discovery-bank
- [S124] [P] Discovery Bank, новость о Live Assist, 2021-05-13 — https://www.discovery.co.za/bank/news-bank-live-assist
- [S125] [P] App Store, Discovery Bank — https://apps.apple.com/za/app/discovery-bank/id1451167079
- [S126] [P] Google Play, Discovery Bank — https://play.google.com/store/apps/details?id=bank.discovery.banking.production.release
- [S127] [P] Cobrowse.io, кейс Klarna — https://cobrowse.io/case-studies/klarna
- [S128] [P] App Store, Klarna — https://apps.apple.com/us/app/klarna-shop-now-pay-later/id1115120118
- [S129] [P] Cobrowse.io, кейс Quicken — https://cobrowse.io/case-studies/quicken
- [S130] [P] App Store, Quicken Simplifi — https://apps.apple.com/us/app/quicken-simplifi-budget-money/id1449777194
- [S131] [P] Cobrowse.io, кейс ShiftMed — https://cobrowse.io/case-studies/shiftmed
- [S132] [P] App Store, ShiftMed — https://apps.apple.com/us/app/shiftmed-nursing-jobs/id1458499789
- [S133] [P] Cobrowse.io, кейс Lightspeed — https://cobrowse.io/case-studies/lightspeed
- [S134] [P] App Store, Lightspeed Retail X — https://apps.apple.com/us/app/lightspeed-retail-x/id920603929
- [S135] [P] App Store, Elan Credit Card (release notes v25.11.3) — https://apps.apple.com/us/app/elan-credit-card/id1027586503
- [S136] [P] Google Play, Elan Credit Card — https://play.google.com/store/apps/details?id=com.elan.icsmobile.elanapp
- [S137] [P] App Store, U.S. Bank Mobile Banking — https://apps.apple.com/us/app/u-s-bank-simpler-faster/id458734623
- [S138] [S] Yahoo Finance / пресс-релиз U.S. Bank, 2023-04-06 — https://finance.yahoo.com/news/cobrowse-marks-three-milestone-millions-141500961.html
- [S139] [P] Google Play, U.S. Bank Mobile Banking — https://play.google.com/store/apps/details?id=com.usbank.mobilebanking
- [S140] [P] Glance blog, 2021-02-26, Intuit SmartLook — https://www.glance.cx/blog/glance-guided-cx-and-intuit-make-tax-season-less-taxing
- [S141] [P] PRNewswire, 2018-05-24, Glance Mobile App Sharing — https://www.prnewswire.com/news-releases/glance-networks-transforms-visual-engagement-platform-adding-new-mobile-app-sharing-capabilities-300654485.html
- [S142] [S] Intuit Community, 2019-06-06, SmartLook в приложении — https://ttlc.intuit.com/community/taxes/discussion/on-phone-app-need-to-screen-share/00/591280
- [S143] [P] Tatra banka, пресс-релиз 2025-07-14 — https://www.tatrabanka.sk/sk/blog/tlacove-spravy/podpora-dialku-meni-sposob-komunikacie-bankou/
- [S144] [P] Unblu, кейс Tatra banka — https://www.unblu.com/en/case-studies/becoming-a-leader-in-digital-banking-customer-experiences
- [S145] [P] App Store, Tatra banka — https://apps.apple.com/us/app/tatra-banka/id397756796
- [S146] [P] App Store, Xfinity Mobile Care — https://apps.apple.com/us/app/xfinity-mobile-care/id6557086597
- [S147] [P] Google Play, Google Support Services (404 при проверке 14.09.2026) — https://play.google.com/store/apps/details?id=com.google.android.apps.helprtc
- [S148] [P] Amazon press, 2013-09-25, Mayday — https://press.aboutamazon.com/2013/9/introducing-the-mayday-button-revolutionary-on-device-tech-support
- [S149] [S] GeekWire, 2018-06-16, Amazon ends Mayday — https://www.geekwire.com/2018/amazon-ends-mayday-live-video-customer-support-fire-tablets-five-years-high-profile-rollout/
- [S150] [P] Glance, Mobile solutions — https://www.glance.cx/guided-cx-platform/mobile-solutions
- [S151] [P] Glance docs, iOS masking — https://docs.glance.cx/developer/sdk/mobile_sdk/masking_ios/
- [S152] [P] Glance docs, Mobile release notes — https://docs.glance.cx/release-notes/Mobile/
- [S153] [P] LogMeIn Rescue, In-App Support SDK for iOS — https://support.logmein.com/rescue/help/rescue-in-app-support-sdk-for-ios
- [S154] [P] LogMeIn Rescue, Android SDK — https://logmeinrescue.github.io/Android-SDK/
- [S155] [P] TeamViewer KB, Mobile SDK — https://www.teamviewer.com/en-us/global/support/knowledge-base/teamviewer-classic/integrations/core-integrations/teamviewer-mobile-software-development-kit-sdk/
- [S156] [P] TeamViewer KB, Assist AR Mobile SDK for iOS — https://www.teamviewer.com/en-us/global/support/knowledge-base/other-products/assist-ar/assist-ar-mobile-sdk/mobile-sdk-for-ios/
- [S157] [P] TeamViewer Community, 2017-10-04, iOS SDK and the App Store — https://community.teamviewer.com/English/discussion/13895/ios-sdk-and-the-app-store
- [S158] [P] BeyondTrust docs, Mobile SDK — https://docs.beyondtrust.com/rs/docs/mobile-sdk
- [S159] [P] App Store, BeyondTrust Support (история версий) — https://apps.apple.com/us/app/beyondtrust-support/id488264551
- [S160] [P] Unblu, Mobile Co-Apping — https://www.unblu.com/en/platform/mobile-co-apping
- [S161] [P] Unblu docs, Configuring mobile co-apping — https://docs.unblu.com/latest/knowledge-base/configuration/collaboration-layers/configuring-mobile-co-apping.html
- [S162] [P] Salesforce Help, SOS retirement, 2026-07-01 — https://help.salesforce.com/s/articleView?id=000380630&language=en_US&type=1
- [S163] [P] Salesforce press, 2014-04-24, Service Cloud SOS — https://www.salesforce.com/news/press-releases/2014/04/24/salesforce-com-unveils-the-future-of-mobile-app-support-launches-salesforce1-service-cloud-sos/
- [S164] [P] Salesforce, Visual Remote Assistant — https://www.salesforce.com/products/service-cloud/features/visual-remote-assistant/
- [S165] [P] Genesys Community, 2023-02-16 — https://community.genesys.com/discussion/is-co-browse-for-web-messaging-supported-on-mobile
- [S166] [P] Genesys AppFoundry, Cobrowse.io — https://appfoundry.genesys.com/filter/genesyscloud/listing/af9a5848-07fd-4021-bce0-663c02970566
- [S167] [P] NICE CXone Help, Co-Browse — https://help.nicecxone.com/content/agent/cxoneagent/cobrowseincxa.htm
- [S168] [P] Cobrowse.io, интеграция NICE — https://cobrowse.io/integrations/nice
- [S169] [P] Cobrowse.io, интеграция Talkdesk — https://cobrowse.io/integrations/talkdesk
- [S170] [P] Talkdesk AppConnect, eGain Cobrowse — https://appconnect.talkdesk.com/apps/egain-cobrowse
- [S171] [P] Twilio changelog, 2020-12-04, Glance for Flex — https://www.twilio.com/en-us/changelog/glance-cobrowsing-and-screen-sharing-is-validated-for-flex
- [S172] [P] Zendesk Marketplace, Cobrowse.io — https://www.zendesk.com/marketplace//apps/support/163655/cobrowseio-for-support/
- [S173] [P] Cobrowse.io, интеграция Intercom — https://cobrowse.io/integrations/intercom
- [S174] [P] Freshworks Marketplace, Cobrowse.io — https://www.freshworks.com/apps/cobrowseio_1/
- [S175] [P] LivePerson, Mobile App Messaging SDK for iOS — https://developers.liveperson.com/mobile-app-messaging-sdk-for-ios-overview.html
- [S176] [P] eGain, Mobile — https://www.egain.com/products/mobile/
- [S177] [P] Zoho Assist SDK — https://www.zoho.com/assist/sdk.html
- [S178] [P] Zoho blog, 2019-12-12, Mobile SDK — https://www.zoho.com/blog/assist/supporting-mobile-devices-is-an-easier-job-now-with-our-mobile-sdk-for-ios-and-android.html
- [S179] [P] GitHub, upscopeio/cobrowsing-ios — https://github.com/upscopeio/cobrowsing-ios
- [S180] [P] UserView docs, Full device screen sharing (iOS) — https://userview.com/docs/sdk/ios/full-device-screen-sharing
- [S181] [P] Fullview Help, 2026-04-10 — https://support.fullview.io/en/articles/6122361-how-to-install-fullview
- [S182] [P] Surfly Help, mobile apps — https://help.surfly.com/en/can-surfly-be-integrated-on-mobile-apps
- [S183] [P] Acquire.io, iOS Cobrowse SDK — https://developer.acquire.io/master/ios/ios-cobrowse-sdk
- [S184] [P] Samesurf blog, 2025-07-21 — https://samesurf.com/blog/samesurf-cobrowsing-excels-on-mobile/
- [S185] [P] Apple, ara.apple.com (screen sharing с советником) — https://ara.apple.com/
- [S186] [S] Apple Community, 2021-08-16 — https://discussions.apple.com/thread/253054832
- [S187] [P] Apple, iPhone User Guide: Share screens during a phone call (iOS 26) — https://support.apple.com/guide/iphone/share-screens-during-a-phone-call-iph316a8f125/ios
- [S188] [P] Samsung, Remote Service — https://www.samsung.com/ca/support/remoteservice/
- [S189] [P] Glance blog, 2019-11-20, Axos Bank — https://www.glance.cx/blog/axos-bank-uses-glance-to-improve-csat-for-customers-using-online-banking
- [S190] [P] Cobrowse.io, Product («Over 50 global enterprises») — https://cobrowse.io/product
- [S191] [P] App Store, GoToAssist Support Customer — https://apps.apple.com/us/app/gotoassist-support-customer/id1413723666
- [S192] [P] Unblu blog, 2024-03-19 — https://www.unblu.com/en/blog/facilitate-ebanking-app-adoption-with-co-apping
- [S193] [P] ВТБ, kdelu.vtb.ru, 21.06.2024, шаринг экрана в Бизнес Платформе — https://kdelu.vtb.ru/articles/na-biznes-platforme-vtb-poyavilas-funkcziya-sharinga-ekrana-polza-i-primenenie/
- [S194] [P] RuStore, Бизнес Платформа ВТБ — https://www.rustore.ru/catalog/app/ru.vtb.smb
- [S195] [P] App Store, Бизнес Импульс (404 при проверке 14.09.2026) — https://apps.apple.com/ru/app/бизнес-импульс/id6444621460
- [S196] [P] Kaspi.kz, справка по безопасности приложения (17.08.2026) — https://guide.kaspi.kz/client/ru/app/security/q15186
- [S197] [P] Webim, FAQ по SDK и мобильному приложению — https://webim.ru/kb/faq/sdk-and-mobile-app.html
- [S198] [S] TAdviser, Webim Co-browsing (2015) — https://www.tadviser.ru/index.php/Продукт:Webim_Co-browsing
- [S199] [P] edna, документация iOS SDK 5.0.0 — https://docs-sdk.edna.ru/ios/5.0.0/design-system/flows
- [S200] [S] Startpack, карточка LiveTex — https://startpack.ru/application/livetex-live-chat
- [S201] [P] LiveTex, SDK v2 — https://livetex.github.io/sdk-v2/site/
- [S202] [P] Naumen Contact Center, функции — https://www.naumen.ru/products/phone/tour/features/
- [S203] [P] Voximplant, Screen sharing guide — https://voximplant.com/docs/guides/sdk/screen-sharing
- [S204] [P] Usedesk, блог (co-browsing в чате) — https://usedesk.ru/blog/news/chat-march
- [S205] [P] VideoForce — https://videoforce.ru/
- [S206] [P] RuStore, Гайд по требованиям к приложениям — https://www.rustore.ru/help/developers/publishing-and-verifying-apps/requirement-apps
- [S207] [P] RuStore, Типы разрешений (недоступна, HTTP 429) — https://www.rustore.ru/help/developers/publishing-and-verifying-apps/declare-app-permissions/permission-types
- [S208] [S] Cleverence, 19.02.2026, безопасность приложений в RuStore — https://www.cleverence.ru/articles/it-i-razrabotka/-bezopasnost-prilozheniy-v-rustore-rukovodstvo-dlya-kompaniy/
- [S209] [P] Huawei AppGallery Review Guidelines, §7 (14.01.2026) — https://developer.huawei.com/consumer/en/doc/app/50104-07
- [S210] [P] Банк России, Сибирское ГУ, 31.08.2022 — https://www.cbr.ru/press/regevent/?id=25136
- [S211] [P] Банк России, признаки мошеннических операций, 11.07.2024 — https://cbr.ru/press/event/?id=18829
- [S212] [P] Банк России, признаки с 01.01.2026 — https://www.cbr.ru/Reception/TopicalMessage/Page/11403
- [S213] [S] Текст 210-ФЗ от 26.06.2026 (копия v2b.ru) — https://www.v2b.ru/documents/federalnyy-zakon-ot-26-06-2026-210-fz/
- [S214] [P] Официальная публикация 210-ФЗ, 26.06.2026 — http://publication.pravo.gov.ru/document/0001202606260070
- [S215] [S] РБК, 08.08.2026, отказ в переводах при вредоносном ПО — https://amp.rbc.ru/rbcnews/rbcfreenews/6a76c79d9a794737182ea38f
- [S216] [S] Клерк, разбор 210-ФЗ — https://www.klerk.ru/buh/articles/704433/
- [S217] [S] iXBT, 08.08.2026 — https://www.ixbt.com/news/2026/08/08/427012-rossiiskie-banki-polucat-dostup-ko-vsem-failam-na-smartfone-klienta-s-1-marta-2027-goda-banki-budut-blokirovat-perevody-s-ustroistv-s-vredonosnym-po.html
- [S218] [P] Т-Банк, блог, 12.08.2024, защита от удалённого доступа — https://www.tbank.ru/finance/blog/save-money/
- [S219] [S] Хабр, 13.01.2025, Play Protect и приложение Т-Банка — https://habr.com/ru/news/873292/
- [S220] [S] Content-Review, 07.06.2026, антивирус Сбера — https://www.content-review.com/articles/74770/
- [S221] [S] СберСова, 25.08.2025 — https://sbersova.ru/sections/protection/pozabottes-o-bezopasnosti-s-besplatnymi-servisami-sbera
- [S222] [S] Право.ру, 07.03.2024 — https://pravo.ru/news/251974/
- [S223] [S] Известия, 07.03.2024, схема с трансляцией экрана — https://iz.ru/1660509/mariia-frolova/podgliadeli-kod-kak-moshenniki-ispolzuiut-funktciiu-transliatcii-ekrana-dlia-krazhi-deneg
- [S224] [S] Bankinform, 10.08.2023, ВТБ о RAT-приложениях — https://bankinform.ru/news/129935
- [S225] [P] Halyk Bank, Security — https://halykbank.kz/en/about-bank/security
- [S226] [P] ПриватБанк, защита от мошенничества — https://privatbank.ua/safeness/fraud-protection
