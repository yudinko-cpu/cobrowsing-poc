//
//  CobrowseClient.swift
//  CobrowsePOC
//
//  Главная точка входа для интеграции cobrowsing-сессии в iOS-приложение.
//
//  Жизненный цикл:
//    idle ─┐
//    ended ┼─► requestingConsent ─► connecting ─► streaming ⇄ reconnecting
//    error ┘                                          │             │
//                                                     └──►  ended ◄─┘
//                                                             │
//                                                             └──► (можно снова стартовать)
//
//  Ключевые свойства:
//    * Из терминальных состояний (idle/ended/error) можно вызывать startSession
//      заново — не нужен рестарт приложения после стопа/сбоя.
//    * Автоматический reconnect транспорта отражается в state как .reconnecting,
//      пользователь видит "восстанавливаем связь" вместо тишины.
//    * Разрывы соединения различаются по причине: штатный стоп → .ended,
//      сеть/сервер/токен → .error с осмысленным сообщением.
//
//  Не импортирует LiveKit напрямую. Работает поверх `CobrowseTransport`.
//  По умолчанию использует `LiveKitTransport`, но принимает любую реализацию
//  протокола — это точка выхода на raw libwebrtc / mediasoup / mock без
//  переписывания бизнес-логики.
//

import Foundation
import Combine

@MainActor
public final class CobrowseClient: ObservableObject {

    // MARK: - Public state

    public enum State: Equatable {
        case idle
        case requestingConsent
        case connecting
        case streaming(code: String)
        /// Транспорт потерял связь и автоматически пытается её восстановить.
        /// Код сессии сохраняется — тот же room, тот же оператор.
        case reconnecting(code: String)
        case ended
        case error(String)

        /// Активна ли сессия сейчас (нельзя запускать новую).
        var isActive: Bool {
            switch self {
            case .requestingConsent, .connecting, .streaming, .reconnecting: return true
            case .idle, .ended, .error: return false
            }
        }
    }

    @Published public private(set) var state: State = .idle

    /// Код, который клиент показывает и диктует оператору.
    /// Доступен во время .streaming и .reconnecting (в реконнекте код тот же).
    public var sessionCode: String? {
        switch state {
        case .streaming(let code), .reconnecting(let code): return code
        default: return nil
        }
    }

    // MARK: - Dependencies

    private let backendURL: URL
    private let urlSession: URLSession
    private let transport: any CobrowseTransport
    private var currentRoomName: String?

    /// Инициализатор с явной инъекцией транспорта.
    /// Используйте для тестов (MockTransport), альтернативных бэкендов
    /// или экспериментов с raw WebRTC-стеком.
    public init(backendURL: URL,
                transport: any CobrowseTransport,
                urlSession: URLSession = .shared) {
        self.backendURL = backendURL
        self.transport = transport
        self.urlSession = urlSession
        self.transport.delegate = self
    }

    /// Convenience: дефолтный LiveKit-транспорт.
    /// Смена этой строки — единственное, что нужно поменять в бизнес-коде
    /// при миграции на другой транспорт.
    public convenience init(backendURL: URL, urlSession: URLSession = .shared) {
        self.init(
            backendURL: backendURL,
            transport: LiveKitTransport(),
            urlSession: urlSession
        )
    }

    // MARK: - Public API

    /// Запустить сессию: consent → backend → transport connect → publish.
    /// Возвращает 6-значный код для передачи оператору.
    ///
    /// Можно вызывать из терминальных состояний (.idle, .ended, .error) —
    /// это же и есть "рестарт после стопа/сбоя без перезапуска приложения".
    /// Из активного состояния (.requestingConsent, .connecting, .streaming,
    /// .reconnecting) кидает `.alreadyActive`.
    @discardableResult
    public func startSession(customerId: String? = nil) async throws -> String {
        guard !state.isActive else { throw CobrowseError.alreadyActive }

        // Cleanup остатков от прошлой сессии. Идемпотентен для transport'а,
        // так что дёшево. Нужен на случай перезапуска из .error, когда
        // соединение могло остаться в полуразобранном виде.
        await transport.unpublishAll()
        await transport.disconnect()
        currentRoomName = nil

        // 1. Явное согласие пользователя (см. ConsentPrompt.swift)
        state = .requestingConsent
        let consented = await ConsentPrompt.requestConsent()
        guard consented else {
            state = .idle
            throw CobrowseError.consentDenied
        }

        // 2. Запросить сессию у backend — получаем код, URL транспорта и токен
        state = .connecting
        let session: SessionCreateResponse
        do {
            session = try await createSessionOnBackend(customerId: customerId)
        } catch {
            state = .error("Не удалось создать сессию: \(error.localizedDescription)")
            throw error
        }
        currentRoomName = session.roomName

        // 3. Подключиться через транспорт (LiveKit / raw / whatever)
        do {
            try await transport.connect(url: session.livekitUrl, token: session.token)
        } catch {
            state = .error("Не удалось подключиться: \(error.localizedDescription)")
            throw error
        }

        // 4. Опубликовать экран + микрофон
        do {
            try await transport.publishScreenShare(options: ScreenShareOptions(
                dimensions: .h720_169,
                fps: 15,
                useBroadcastExtension: false
            ))
            try await transport.publishAudio(options: AudioOptions(
                echoCancellation: true,
                noiseSuppression: true
            ))
        } catch {
            await transport.disconnect()
            state = .error("Не удалось запустить захват экрана: \(error.localizedDescription)")
            throw error
        }

        state = .streaming(code: session.code)
        return session.code
    }

    /// Остановить сессию по инициативе клиента.
    ///
    /// Безопасен из любого состояния — идемпотентный cleanup + переход в .ended.
    /// Из .ended/.idle/.error фактически no-op на transport'е (тот сам идемпотентный),
    /// но state форсируем в .ended для консистентности UI.
    public func stopSession() async {
        await transport.unpublishAll()
        await transport.disconnect()
        currentRoomName = nil
        state = .ended
    }

    // MARK: - Backend

    private func createSessionOnBackend(customerId: String?) async throws -> SessionCreateResponse {
        var req = URLRequest(url: backendURL.appendingPathComponent("session/create"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        let body: [String: String] = customerId.map { ["customerId": $0] } ?? [:]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw CobrowseError.backendError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        return try JSONDecoder().decode(SessionCreateResponse.self, from: data)
    }

    private struct SessionCreateResponse: Decodable {
        let code: String
        let roomName: String
        /// Название поля историческое (осталось от LiveKit-only реализации).
        /// В нейтральном контракте — это URL транспорта.
        let livekitUrl: String
        let token: String
        let expiresIn: Int
    }
}

// MARK: - CobrowseTransportDelegate

extension CobrowseClient: CobrowseTransportDelegate {

    // Все три метода nonisolated: транспорт может звать их с любого actor,
    // и мы явно хопаем в MainActor через Task для мутации @Published state.

    public nonisolated func transport(_ transport: any CobrowseTransport,
                                      didChangeConnectionState connState: ConnectionState) {
        #if DEBUG
        print("[CobrowseClient] transport state: \(connState)")
        #endif
        Task { @MainActor in
            // Отражаем авто-reconnect транспорта в user-visible state.
            // Код сессии переносим — реконнект идёт в ту же комнату.
            switch (self.state, connState) {
            case (.streaming(let code), .reconnecting):
                self.state = .reconnecting(code: code)
            case (.reconnecting(let code), .connected):
                self.state = .streaming(code: code)
            default:
                // Остальные переходы либо шумовые (.connected → .connected при
                // первом коннекте), либо обрабатываются в didDisconnectWithReason.
                break
            }
        }
    }

    public nonisolated func transport(_ transport: any CobrowseTransport,
                                      didDisconnectWithReason reason: TransportDisconnectReason) {
        Task { @MainActor in
            // Если уже в терминальном состоянии — колбэк пришёл от нашего же
            // disconnect'а в stopSession() / startSession() cleanup. State уже
            // выставлен, повторно не трогаем.
            guard self.state.isActive else { return }

            switch reason {
            case .userInitiated:
                // Штатный стоп по инициативе клиента.
                self.state = .ended
            case .serverClosed:
                // Backend вызвал deleteRoom (оператор завершил сессию).
                self.state = .error("Оператор завершил сессию")
            case .networkError:
                // Транспорт исчерпал свой auto-reconnect и сдался.
                self.state = .error("Соединение потеряно. Проверьте сеть и начните заново.")
            case .tokenExpired:
                self.state = .error("Сессия истекла. Начните новую.")
            case .unknown:
                self.state = .error("Сессия прервана")
            }
            self.currentRoomName = nil
        }
    }

    public nonisolated func transport(_ transport: any CobrowseTransport,
                                      didReceiveData data: Data,
                                      topic: String,
                                      fromParticipantIdentity identity: String?) {
        // TODO P1: маршрутизировать по topic ("annotations", "control", ...) в соответствующий handler.
        // Здесь пусто, потому что рисование аннотаций поверх UI — задача уровня приложения,
        // а не SDK. SDK лишь доставляет байты.
    }
}

// MARK: - Errors

public enum CobrowseError: LocalizedError {
    case consentDenied
    case alreadyActive
    case backendError(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .consentDenied:          return "Пользователь не дал согласие на запись экрана"
        case .alreadyActive:          return "Сессия уже активна"
        case .backendError(let code): return "Сервер вернул ошибку \(code)"
        }
    }
}
