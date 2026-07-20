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

    /// Чистая модель + семантика мёржа (зеркалит web anno.ts).
    private let state = AnnoState()

    /// Идентичность локального участника (клиента). Ops с этим `author`
    /// игнорируются — клиент не может быть автором аннотаций (§6.4).
    /// nil → принимаем всё: на клиенте удалённые участники это только операторы,
    /// клиент сам аннотации не публикует. Полноценный role-гейт (name=='Customer')
    /// подключим в ANNO-2, когда транспорт отдаст identity локального участника.
    public var localIdentity: String?

    private var expiryTask: Task<Void, Never>?
    private let pointerTtlMs: Double = 1000
    private let expiryTickNs: UInt64 = 100_000_000  // 0.1 c

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
    /// Как следствие, «Customer» не может быть автором: клиент сам не публикует,
    /// а LiveKit не возвращает локальные data-сообщения отправителю.
    public func handle(data: Data, topic: String, from identity: String?) {
        guard topic == AnnoProtocol.topic, var msg = AnnoCodec.decode(data) else { return }
        if let identity, !identity.isEmpty { msg.author = identity }
        apply(msg)
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
    }

    // MARK: - Фейд указок

    /// MainActor-Task-цикл вместо Timer: под Swift 6 strict concurrency Timer со
    /// @Sendable-блоком, захватывающим @MainActor self, недопустим. Task,
    /// созданный в @MainActor-контексте, наследует MainActor — гонок нет.
    private func ensureExpiryLoop() {
        guard expiryTask == nil, !state.pointers.isEmpty else { return }
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.expiryTickNs ?? 100_000_000)
                guard let self else { return }
                self.tickExpiry()
                if self.state.pointers.isEmpty {
                    self.stopExpiryLoop()
                    return
                }
            }
        }
    }

    private func tickExpiry() {
        let nowMs = Date().timeIntervalSince1970 * 1000
        state.expirePointers(now: nowMs, ttlMs: pointerTtlMs)
        publish()
    }

    private func stopExpiryLoop() {
        expiryTask?.cancel()
        expiryTask = nil
    }

    #if DEBUG
    /// Демо-аннотации для проверки координатного маппинга (ANNO-1 AC3).
    /// Эллипс отцентрирован на (0.5, 0.5) — маркер обязан лечь ровно в центр
    /// overlay-окна на любом устройстве. Триггерится DEBUG-жестом в ContentView.
    public func injectSampleAnnotations() {
        let now = Date().timeIntervalSince1970 * 1000
        let a = "agent-demo"
        apply(AnnoMsg(op: "add", author: a, ts: now, id: "\(a):center",
                      kind: "shape", color: "#0a84ff", w: 0.006,
                      from: [0.47, 0.47], to: [0.53, 0.53], shape: "ellipse", fill: true))
        apply(AnnoMsg(op: "add", author: a, ts: now, id: "\(a):arrow",
                      kind: "arrow", color: "#ff375f", w: 0.006,
                      from: [0.2, 0.2], to: [0.5, 0.5]))
        apply(AnnoMsg(op: "add", author: a, ts: now, id: "\(a):path",
                      kind: "path", color: "#30d158", w: 0.008,
                      pts: [[0.15, 0.8], [0.3, 0.72], [0.45, 0.82], [0.6, 0.72]]))
        apply(AnnoMsg(op: "add", author: a, ts: now, id: "\(a):text",
                      kind: "text", color: "#bf5af2", at: [0.1, 0.6], text: "Нажмите здесь", size: 0.035))
        apply(AnnoMsg(op: "pointer", author: "agent-demo2", ts: now,
                      color: "#ffd60a", at: [0.78, 0.35]))
    }
    #endif
}
