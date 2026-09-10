//
//  ChatStore.swift
//  CobrowsePOC
//
//  Стор чата поддержки на клиенте. Сообщения едут тем же data-топиком и тем же
//  конвертом `AnnoMsg`, что аннотации (`op: "chat"`, полезная нагрузка — id + text),
//  но состоянием аннотаций НЕ являются: AnnotationStore их пропускает, в
//  sync-state они не входят. Истории нет by design — всё живёт в памяти одной
//  сессии и сбрасывается хостом вместе с overlay (ContentView → reset()).
//
//  Наполняется из транспорта (CobrowseClient.didReceiveData → handle()),
//  своё сообщение добавляется оптимистично из CobrowseClient.sendChatMessage.
//  Combine-only, без UIKit — UI живёт в приложении (SupportChatView, SupportFAB).
//
//  Зеркало web-стороны — `web-agent/lib/chat.ts` (санитизация и ключ дедупа
//  обязаны совпадать).
//

import Foundation
import Combine

/// Сообщение чата поддержки (только в памяти, живёт до конца сессии).
public struct ChatMessage: Identifiable, Equatable {
    /// Ключ дедупа `"<author>|<wire id>"`; author — аутентифицированная identity.
    public let id: String
    /// Identity оператора; для своих сообщений — псевдо-автор "client".
    public let author: String
    public let text: String
    /// Миллисекунды с эпохи, как `AnnoMsg.ts`.
    public let ts: Double
    public let isMine: Bool

    public init(id: String, author: String, text: String, ts: Double, isMine: Bool) {
        self.id = id; self.author = author; self.text = text; self.ts = ts; self.isMine = isMine
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

    /// Ключи уже принятых сообщений — reliable-канал может доставить повтор.
    private var seen = Set<String>()

    public init() {}

    // MARK: - Приём

    /// Точка входа с транспорта: фильтр по топику + декод + только `op == "chat"`.
    /// Безопасно вызывать с любыми данными — чужие топики, другие ops и битый
    /// JSON молча игнорируются.
    ///
    /// Анти-спуфинг — как в AnnotationStore: `author` берём из аутентифицированной
    /// identity отправителя, а не из payload. Role-гейт не нужен: на клиенте все
    /// удалённые участники — операторы, а свои сообщения LiveKit не эхоит.
    public func handle(data: Data, topic: String, from identity: String?) {
        guard topic == AnnoProtocol.topic,
              var msg = AnnoCodec.decode(data),
              msg.op == "chat" else { return }
        if let identity, !identity.isEmpty { msg.author = identity }
        guard let text = Self.sanitize(msg.text) else { return }

        let key = "\(msg.author)|\(msg.id ?? String(msg.ts))"
        guard seen.insert(key).inserted else { return }

        messages.append(ChatMessage(id: key, author: msg.author, text: text, ts: msg.ts, isMine: false))
        if !isOpen { unreadCount += 1 }
    }

    /// Оптимистичное добавление своего сообщения: LiveKit не возвращает
    /// отправителю его же data, поэтому применяем локально сразу.
    public func appendLocal(text: String, id: String, ts: Double) {
        let key = "client|\(id)"
        seen.insert(key)
        messages.append(ChatMessage(id: key, author: "client", text: text, ts: ts, isMine: true))
    }

    // MARK: - Жизненный цикл

    public func markAllRead() {
        unreadCount = 0
    }

    /// Полная очистка по завершении сессии (истории нет by design).
    public func reset() {
        messages.removeAll()
        seen.removeAll()
        unreadCount = 0
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
