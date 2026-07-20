//
//  CobrowseTransport.swift
//  CobrowsePOC
//
//  Абстракция транспортного слоя. Прячет конкретную реализацию (LiveKit,
//  raw libwebrtc, mediasoup, что угодно) от бизнес-логики CobrowseClient.
//
//  Всё, что видит клиентский код — этот протокол и нейтральные типы ниже.
//  Ни одного публичного упоминания LiveKit в этом файле нет.
//
//  Замена LiveKit на другой транспорт = новая реализация протокола + одна
//  строка в CobrowseClient.init. См. LiveKitTransport.swift как эталон.
//

import Foundation

// MARK: - Neutral types (без зависимостей от транспорта)

/// Состояние подключения. Единый жизненный цикл для любого транспорта.
public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

/// Причина разрыва соединения. Нужна для UX и решений о retry.
public enum TransportDisconnectReason: Sendable {
    /// Штатное завершение по инициативе локальной стороны.
    case userInitiated
    /// Комната закрыта сервером (например, backend вызвал deleteRoom).
    case serverClosed
    /// Потеря сети, невозможность восстановиться.
    case networkError
    /// JWT протух и не был обновлён.
    case tokenExpired
    /// Всё остальное.
    case unknown
}

/// Разрешение видео для screen-share. Транспорт-нейтральный тип.
public struct VideoDimensions: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let h240_169 = VideoDimensions(width: 426, height: 240)
    public static let h360_169 = VideoDimensions(width: 640, height: 360)
    public static let h480_169 = VideoDimensions(width: 854, height: 480)
    public static let h720_169 = VideoDimensions(width: 1280, height: 720)
    public static let h1080_169 = VideoDimensions(width: 1920, height: 1080)
}

/// Предпочтительный видео-кодек. Финальный кодек определяет SFU
/// на основе `enabled_codecs` в конфиге LiveKit + возможностей клиентов.
/// Если предпочтение не поддерживается — SFU выберет из доступных.
public enum VideoCodec: String, CaseIterable, Sendable {
    /// Hardware-accelerated на iOS (VideoToolbox), лучшая совместимость. Дефолт.
    case h264
    /// Software-encoded, широкая браузерная поддержка, хуже сжатие чем VP9/AV1.
    case vp8
    /// Software-encoded на iOS, ~30% лучше VP8 по битрейту при том же качестве.
    /// Chrome/Firefox/Safari 14+, Edge — везде декодируется.
    case vp9
    /// Software-encoded, ~50% лучше H264. Дорогой по CPU/батарее, hardware-encode
    /// на iOS нет. Декодинг: Chrome, Edge, Firefox 100+; Safari частично.
    case av1

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .vp8:  return "VP8"
        case .vp9:  return "VP9"
        case .av1:  return "AV1"
        }
    }
}

/// Параметры screen-share публикации.
public struct ScreenShareOptions: Sendable, Equatable {
    public var dimensions: VideoDimensions
    public var fps: Int
    public var codec: VideoCodec
    /// Верхняя граница битрейта в kbps. nil = LiveKit сам решает (адаптивно).
    /// Типичные значения: 500 kbps (SD/тонкая сеть), 1500 kbps (HD), 3500 kbps (FHD).
    public var maxBitrateKbps: Int?
    /// false = ReplayKit RPScreenRecorder (только это приложение, P0)
    /// true  = Broadcast Extension (весь экран устройства, P2)
    public var useBroadcastExtension: Bool

    public init(dimensions: VideoDimensions = .h720_169,
                fps: Int = 15,
                codec: VideoCodec = .h264,
                maxBitrateKbps: Int? = 500,
                useBroadcastExtension: Bool = false) {
        self.dimensions = dimensions
        self.fps = fps
        self.codec = codec
        self.maxBitrateKbps = maxBitrateKbps
        self.useBroadcastExtension = useBroadcastExtension
    }
}

/// Параметры публикации микрофона.
public struct AudioOptions: Sendable {
    public var echoCancellation: Bool
    public var noiseSuppression: Bool

    public init(echoCancellation: Bool = true, noiseSuppression: Bool = true) {
        self.echoCancellation = echoCancellation
        self.noiseSuppression = noiseSuppression
    }
}

/// Ошибки транспортного слоя.
public enum TransportError: LocalizedError {
    case notConnected
    case alreadyPublishing
    case publishFailed(String)
    case connectFailed(String)
    case underlying(Error)

    public var errorDescription: String? {
        switch self {
        case .notConnected:            return "Транспорт не подключён"
        case .alreadyPublishing:       return "Публикация уже активна"
        case .publishFailed(let m):    return "Не удалось опубликовать: \(m)"
        case .connectFailed(let m):    return "Не удалось подключиться: \(m)"
        case .underlying(let e):       return e.localizedDescription
        }
    }
}

// MARK: - Delegate

/// События транспортного слоя. Все методы имеют пустую default-реализацию,
/// имплементор конформит только те, что нужны.
///
/// Вызывается со стороны транспорта, не обязательно с main actor.
/// Имплементору отвечать за хоп в свой actor при необходимости.
public protocol CobrowseTransportDelegate: AnyObject {

    /// Смена состояния подключения. Полезно для индикатора reconnect в UI.
    func transport(_ transport: any CobrowseTransport,
                   didChangeConnectionState state: ConnectionState)

    /// Соединение разорвано (штатно или из-за ошибки).
    func transport(_ transport: any CobrowseTransport,
                   didDisconnectWithReason reason: TransportDisconnectReason)

    /// Пришло data-сообщение от удалённого участника.
    /// Используется для аннотаций, команд, произвольных событий.
    func transport(_ transport: any CobrowseTransport,
                   didReceiveData data: Data,
                   topic: String,
                   fromParticipantIdentity identity: String?)

    /// Удалённый участник (оператор) присоединился к сессии.
    /// Нужно для ресинка аннотаций позднему подключению (sync-state).
    func transport(_ transport: any CobrowseTransport,
                   didConnectParticipant identity: String)

    /// Удалённый участник (оператор) покинул сессию.
    /// Нужно, чтобы снять его аннотации у всех (removeAuthor).
    func transport(_ transport: any CobrowseTransport,
                   didDisconnectParticipant identity: String)
}

public extension CobrowseTransportDelegate {
    func transport(_ transport: any CobrowseTransport,
                   didChangeConnectionState state: ConnectionState) {}
    func transport(_ transport: any CobrowseTransport,
                   didDisconnectWithReason reason: TransportDisconnectReason) {}
    func transport(_ transport: any CobrowseTransport,
                   didReceiveData data: Data,
                   topic: String,
                   fromParticipantIdentity identity: String?) {}
    func transport(_ transport: any CobrowseTransport,
                   didConnectParticipant identity: String) {}
    func transport(_ transport: any CobrowseTransport,
                   didDisconnectParticipant identity: String) {}
}

// MARK: - Transport protocol

/// Основной контракт транспорта. Реализация ниже — LiveKitTransport.
/// Другие возможные реализации: RawWebRTCTransport, MediasoupTransport, MockTransport (для тестов).
public protocol CobrowseTransport: AnyObject {

    var delegate: CobrowseTransportDelegate? { get set }
    var connectionState: ConnectionState { get }

    /// Подключение к сессии. url зависит от реализации:
    /// — LiveKit: wss://livekit.example.com
    /// — raw WebRTC: URL signaling-сервера
    func connect(url: String, token: String) async throws

    /// Разрыв соединения. Идемпотентен — повторный вызов безопасен.
    func disconnect() async

    /// Публикация screen-share трека.
    /// Для in-app (P0) — под капотом ReplayKit RPScreenRecorder.
    /// Для full device (P2) — Broadcast Extension через App Group.
    func publishScreenShare(options: ScreenShareOptions) async throws

    /// Заменить активную screen-share публикацию с новыми параметрами.
    /// LiveKit не умеет hot-swap кодек/битрейт — под капотом unpublish + publish.
    /// Пользователь увидит короткий чёрный кадр (< 1с), сессия не рвётся.
    ///
    /// Если публикации нет — ведёт себя как обычный publishScreenShare.
    func republishScreenShare(options: ScreenShareOptions) async throws

    /// Публикация микрофона.
    func publishAudio(options: AudioOptions) async throws

    /// Снять все локальные публикации. Не разрывает соединение —
    /// после этого можно опубликовать заново.
    func unpublishAll() async

    /// Отправка data-сообщения удалённой стороне.
    /// - Parameter topic: логический канал ("annotations", "control", "cursor", ...)
    /// - Parameter reliable: true = гарантированная доставка (аннотации),
    ///                       false = best-effort (курсор реалтайм)
    /// - Parameter destinationIdentities: кому доставить. Пустой массив = всем
    ///   (broadcast). Адресная доставка нужна для ресинка: снапшот аннотаций
    ///   уходит только тому оператору, который его запросил.
    func sendData(_ data: Data,
                  topic: String,
                  reliable: Bool,
                  destinationIdentities: [String]) async throws
}

public extension CobrowseTransport {
    /// Broadcast-вариант: доставить всем участникам сессии.
    func sendData(_ data: Data, topic: String, reliable: Bool) async throws {
        try await sendData(data, topic: topic, reliable: reliable, destinationIdentities: [])
    }
}
