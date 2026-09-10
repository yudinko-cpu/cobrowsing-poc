//
//  AnnotationStore.swift
//  CobrowsePOC
//
//  SwiftUI-обёртка над `AnnoState` (чистый reducer из Annotation.swift).
//  Держит канонический стор аннотаций на клиенте, публикует снапшоты для
//  overlay-рендера, гасит протухшие указки по таймеру, гейтит права.
//
//  Наполняется из транспорта (ANNO-2: CobrowseClient.didReceiveData → handle()).
//  Combine-only, без UIKit — рендер живёт в AnnotationOverlayWindow.swift.
//
//  См. docs/annotations-plan.md (§6 мульти-юзер, §8 iOS overlay).
//

import Foundation
import Combine

@MainActor
public final class AnnotationStore: ObservableObject {

    /// Персистентные аннотации (path/arrow/text/shape) для рендера.
    @Published public private(set) var annotations: [Annotation] = []
    /// Эфемерные указки операторов (гаснут по TTL).
    @Published public private(set) var pointers: [AnnoPointer] = []
    /// Эфемерные клики указкой (расходящееся кольцо).
    @Published public private(set) var clicks: [AnnoClick] = []

    /// Чистая модель + семантика мёржа (зеркалит web anno.ts).
    private let state = AnnoState()

    /// Идентичность локального участника (клиента). Ops с этим `author`
    /// игнорируются — клиент не может быть автором аннотаций (§6.4).
    /// nil → принимаем всё: на клиенте удалённые участники это только операторы,
    /// клиент сам аннотации не публикует. Полноценный role-гейт (name=='Customer')
    /// подключим в ANNO-2, когда транспорт отдаст identity локального участника.
    public var localIdentity: String?

    /// Пришёл `sync-req` от оператора (аутентифицированная identity в параметре).
    /// Клиент — канонический стор, поэтому именно он отвечает адресным
    /// `sync-state`. Проводку делает CobrowseClient (ANNO-6).
    public var onSyncRequest: ((String) -> Void)?

    private var expiryTask: Task<Void, Never>?
    private let pointerTtlMs: Double = 1000
    // ~30 fps: этого хватает и на плавное угасание указки, и на анимацию
    // кольца клика (600 мс). Тик крутится только пока есть живые эфемериды.
    private let expiryTickNs: UInt64 = 33_000_000

    public init() {}

    // MARK: - Приём

    /// Точка входа с транспорта: фильтр по топику + декод + применение.
    /// Безопасно вызывать с любыми данными — чужие топики и битый JSON молча
    /// игнорируются.
    ///
    /// Анти-спуфинг: `author` берём из аутентифицированной identity отправителя
    /// (LiveKit проверяет её по JWT), а НЕ из поля payload. В честном случае они
    /// совпадают; при подмене — сообщение атрибутируется реальному отправителю,
    /// поэтому один оператор не может выдать себя за другого, стереть или
    /// дополнить чужие аннотации (append/remove гейтятся по author в AnnoState).
    /// Как следствие, «Customer» не может быть автором аннотаций: клиент публикует
    /// только `chat` (единственный op, который ему разрешён; здесь он пропускается,
    /// а обрабатывается в ChatStore), а LiveKit не возвращает локальные
    /// data-сообщения отправителю.
    public func handle(data: Data, topic: String, from identity: String?) {
        guard topic == AnnoProtocol.topic, var msg = AnnoCodec.decode(data) else { return }
        if let identity, !identity.isEmpty { msg.author = identity }

        switch msg.op {
        case "sync-req":
            // Оператор просит текущее состояние (позднее подключение / F5).
            // Отвечает CobrowseClient — адресно, снапшотом (ANNO-6).
            onSyncRequest?(msg.author)
        case "sync-state":
            // Клиент — сам канонический источник и снапшоты извне не принимает:
            // иначе оператор мог бы подсунуть аннотации с чужим авторством.
            break
        case "chat", "typing", "chat-sync":
            // Ops чата поддержки (сообщение, «печатает», история) — не аннотации;
            // их принимает ChatStore (CobrowseClient.didReceiveData маршрутизирует
            // те же байты и туда), историю шлёт сам телефон.
            break
        default:
            apply(msg)
        }
    }

    /// Применить уже разобранное сообщение.
    public func apply(_ msg: AnnoMsg) {
        let localId = localIdentity
        state.apply(msg) { author in localId == nil || author != localId }
        publish()
        ensureExpiryLoop()
    }

    /// Снять аннотации ушедшего оператора (ANNO-2/5: participantDisconnected).
    public func removeAuthor(_ author: String) {
        state.removeAuthor(author)
        publish()
    }

    // MARK: - Жизненный цикл overlay

    /// Снапшот всех персистентных аннотаций (без эфемерных указок) —
    /// тело ответа `sync-state`.
    public func snapshot() -> [Annotation] {
        state.snapshot()
    }

    /// Полная очистка при снятии overlay (.ended / .error).
    public func reset() {
        state.clearAll()
        stopExpiryLoop()
        publish()
    }

    // MARK: - Публикация снапшотов

    private func publish() {
        annotations = state.snapshot()
        pointers = Array(state.pointers.values)
        clicks = Array(state.clicks.values)
    }

    // MARK: - Фейд указок

    /// MainActor-Task-цикл вместо Timer: под Swift 6 strict concurrency Timer со
    /// @Sendable-блоком, захватывающим @MainActor self, недопустим. Task,
    /// созданный в @MainActor-контексте, наследует MainActor — гонок нет.
    private func ensureExpiryLoop() {
        guard expiryTask == nil, !(state.pointers.isEmpty && state.clicks.isEmpty) else { return }
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.expiryTickNs ?? 33_000_000)
                guard let self else { return }
                self.tickExpiry()
                if self.state.pointers.isEmpty && self.state.clicks.isEmpty {
                    self.stopExpiryLoop()
                    return
                }
            }
        }
    }

    private func tickExpiry() {
        let nowMs = Date().timeIntervalSince1970 * 1000
        state.expirePointers(now: nowMs, ttlMs: pointerTtlMs)
        state.expireClicks(now: nowMs)
        publish()
    }

    private func stopExpiryLoop() {
        expiryTask?.cancel()
        expiryTask = nil
    }
}
