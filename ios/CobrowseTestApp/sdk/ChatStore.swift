//
//  ChatStore.swift
//  CobrowsePOC
//
//  Стор чата поддержки на клиенте. Сообщения и «печатает» едут тем же
//  data-топиком и тем же конвертом `AnnoMsg`, что аннотации (`op: "chat"` —
//  id + text; `op: "typing"` — typing: true/false), но состоянием аннотаций НЕ
//  являются: AnnotationStore их пропускает, в sync-state они не входят.
//
//  Телефон — канонический стор сессии и для чата (как для аннотаций): история
//  живёт здесь в памяти, никуда не пишется и по sync-req уезжает запросившему
//  оператору пакетами `chat-sync` (CobrowseClient.sendChatHistory) — поздний
//  оператор и вкладка после F5 видят всю переписку. Сбрасывается хостом вместе
//  с overlay по концу сессии (ContentView → reset()).
//
//  Наполняется из транспорта (CobrowseClient.didReceiveData → handle()),
//  своё сообщение добавляется оптимистично из CobrowseClient.sendChatMessage.
//  Combine-only, без UIKit — UI живёт в приложении (SupportChatView, SupportFAB).
//
//  Зеркало web-стороны — `web-agent/lib/chat.ts` (санитизация, ключ дедупа,
//  троттлинг и TTL «печатает» обязаны совпадать).
//

import Foundation
import Combine

/// Сообщение чата поддержки (только в памяти, живёт до конца сессии).
public struct ChatMessage: Identifiable, Equatable {
    /// Ключ дедупа `"<author>|<wire id>"`; author — аутентифицированная identity.
    public let id: String
    /// Id на проводе ("author:counter") — нужен, чтобы отдать историю (chat-sync)
    /// с теми же id, по которым операторы дедупят живые сообщения.
    public let wireId: String
    /// Identity оператора; для своих сообщений — AnnoProtocol.clientPseudoAuthor.
    public let author: String
    public let text: String
    /// Миллисекунды с эпохи, как `AnnoMsg.ts`.
    public let ts: Double
    public let isMine: Bool

    public init(id: String, wireId: String, author: String, text: String, ts: Double, isMine: Bool) {
        self.id = id; self.wireId = wireId; self.author = author; self.text = text; self.ts = ts; self.isMine = isMine
    }
}

@MainActor
public final class ChatStore: ObservableObject {

    /// Все сообщения сессии в порядке поступления.
    @Published public private(set) var messages: [ChatMessage] = []
    /// Входящие, которые пользователь ещё не видел (бейдж на FAB).
    @Published public private(set) var unreadCount = 0
    /// Экран чата открыт: входящие не копят unread, FAB прячется. @Published,
    /// потому что SupportFAB наблюдает стор напрямую (вложенный ObservableObject
    /// не пробрасывает изменения через CobrowseClient).
    @Published public var isOpen = false {
        didSet { if isOpen { markAllRead() } }
    }
    /// Операторы, которые сейчас печатают: identity → момент последнего
    /// heartbeat по ЛОКАЛЬНЫМ часам (мс). Локальным, а не по `ts` отправителя —
    /// рассинхрон часов телефона и браузера не должен ломать TTL.
    @Published public private(set) var typing: [String: Double] = [:]

    /// Отправитель: heartbeat «печатает» не чаще этого интервала (мс).
    /// Зеркало TYPING_HEARTBEAT_MS в chat.ts. nonisolated — константа нужна
    /// в default-аргументе TypingTracker.init, который вычисляется вне актора.
    public nonisolated static let typingHeartbeatMs: Double = 2000
    /// Получатель: без нового heartbeat индикатор гаснет через это время (мс).
    /// Зеркало TYPING_TTL_MS в chat.ts.
    public nonisolated static let typingTtlMs: Double = 5000

    /// Ключи уже принятых сообщений — reliable-канал может доставить повтор.
    private var seen = Set<String>()
    private var typingExpiryTask: Task<Void, Never>?

    public init() {}

    // MARK: - Приём

    /// Точка входа с транспорта: фильтр по топику + декод + только ops чата.
    /// Безопасно вызывать с любыми данными — чужие топики, другие ops и битый
    /// JSON молча игнорируются.
    ///
    /// Анти-спуфинг — как в AnnotationStore: `author` берём из аутентифицированной
    /// identity отправителя, а не из payload. Role-гейт не нужен: на клиенте все
    /// удалённые участники — операторы, а свои сообщения LiveKit не эхоит.
    public func handle(data: Data, topic: String, from identity: String?) {
        guard topic == AnnoProtocol.topic, var msg = AnnoCodec.decode(data) else { return }
        if let identity, !identity.isEmpty { msg.author = identity }

        switch msg.op {
        case "chat":
            guard let text = Self.sanitize(msg.text) else { return }
            let wireId = msg.id ?? String(msg.ts)
            let key = "\(msg.author)|\(wireId)"
            guard seen.insert(key).inserted else { return }
            messages.append(ChatMessage(id: key, wireId: wireId, author: msg.author, text: text, ts: msg.ts, isMine: false))
            if !isOpen { unreadCount += 1 }
            // Сообщение пришло — «печатает» этого автора снимаем сразу.
            typing.removeValue(forKey: msg.author)

        case "typing":
            if msg.typing == true {
                typing[msg.author] = Date().timeIntervalSince1970 * 1000
                ensureTypingExpiryLoop()
            } else {
                typing.removeValue(forKey: msg.author)
            }

        default:
            return // остальные ops — аннотации, их принимает AnnotationStore
        }
    }

    /// Оптимистичное добавление своего сообщения: LiveKit не возвращает
    /// отправителю его же data, поэтому применяем локально сразу.
    public func appendLocal(text: String, id: String, ts: Double) {
        let author = AnnoProtocol.clientPseudoAuthor
        let key = "\(author)|\(id)"
        seen.insert(key)
        messages.append(ChatMessage(id: key, wireId: id, author: author, text: text, ts: ts, isMine: true))
    }

    // MARK: - История для chat-sync

    /// Бюджет одного пакета chat-sync в байтах. Практический потолок data-пакета
    /// LiveKit — 15 КБ (MAX_PACKET_BYTES в anno.ts); запас — на JSON-экранирование
    /// и конверт.
    public nonisolated static let historyBatchBytes = 12_000

    /// История сессии в порядке поступления — тело пакетов chat-sync.
    public func historyItems() -> [ChatItem] {
        messages.map { ChatItem(id: $0.wireId, author: $0.author, text: $0.text, ts: $0.ts) }
    }

    /// Разбить историю на пакеты по бюджету байт: оценка по UTF-8 длинам полей
    /// плюс накладные JSON на элемент. Порядок сохраняется; один элемент всегда
    /// влезает (текст ограничен maxChatLen).
    public static func chunkHistory(_ items: [ChatItem], maxBytes: Int = historyBatchBytes) -> [[ChatItem]] {
        var out: [[ChatItem]] = []
        var batch: [ChatItem] = []
        var size = 0
        for item in items {
            let estimate = 48 + item.id.utf8.count + item.author.utf8.count + item.text.utf8.count
            if !batch.isEmpty && size + estimate > maxBytes {
                out.append(batch)
                batch = []
                size = 0
            }
            batch.append(item)
            size += estimate
        }
        if !batch.isEmpty { out.append(batch) }
        return out
    }

    /// Оператор отключился — снять его «печатает» (сообщения остаются).
    public func removeAuthor(_ author: String) {
        typing.removeValue(forKey: author)
    }

    // MARK: - Жизненный цикл

    public func markAllRead() {
        unreadCount = 0
    }

    /// Полная очистка по завершении сессии (история живёт только в рамках сессии).
    public func reset() {
        messages.removeAll()
        seen.removeAll()
        unreadCount = 0
        typing.removeAll()
        stopTypingExpiryLoop()
    }

    // MARK: - TTL «печатает»

    /// MainActor-Task-цикл вместо Timer (как в AnnotationStore): крутится только
    /// пока кто-то печатает, и сам себя гасит.
    private func ensureTypingExpiryLoop() {
        guard typingExpiryTask == nil else { return }
        typingExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                let now = Date().timeIntervalSince1970 * 1000
                let stale = self.typing.filter { now - $0.value > Self.typingTtlMs }.map(\.key)
                for author in stale { self.typing.removeValue(forKey: author) }
                if self.typing.isEmpty {
                    self.stopTypingExpiryLoop()
                    return
                }
            }
        }
    }

    private func stopTypingExpiryLoop() {
        typingExpiryTask?.cancel()
        typingExpiryTask = nil
    }

    // MARK: - Санитизация

    /// trim + лимит `maxChatLen`; nil — пусто. Единая точка для входящих и
    /// исходящих, зеркалит `clampChatText` в web (там тоже trim → срез).
    static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > AnnoProtocol.maxChatLen ? String(t.prefix(AnnoProtocol.maxChatLen)) : t
    }
}

// MARK: - Отправитель «печатает»

/// Решает, что слать при изменении черновика:
///   • черновик непустой: `true` сразу при первом символе, дальше — не чаще
///     `typingHeartbeatMs` (если heartbeat'ы кончились, получатель гасит по TTL);
///   • черновик опустел: один `false`;
///   • после отправки сообщения — `reset()`: получатели снимут индикатор по
///     самому `chat`, отдельный `false` не нужен.
/// Зеркало `TypingTracker` в web-agent/lib/chat.ts — семантика обязана совпадать.
public struct TypingTracker {
    private var announced = false
    private var lastSentMs: Double = 0
    private let heartbeatMs: Double

    public init(heartbeatMs: Double = ChatStore.typingHeartbeatMs) {
        self.heartbeatMs = heartbeatMs
    }

    /// true — слать heartbeat, false — слать «перестал», nil — слать нечего.
    public mutating func onDraftChange(nonEmpty: Bool, nowMs: Double) -> Bool? {
        if nonEmpty {
            if !announced || nowMs - lastSentMs >= heartbeatMs {
                announced = true
                lastSentMs = nowMs
                return true
            }
            return nil
        }
        guard announced else { return nil }
        announced = false
        lastSentMs = 0
        return false
    }

    public mutating func reset() {
        announced = false
        lastSentMs = 0
    }
}
