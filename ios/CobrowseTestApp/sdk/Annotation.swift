//
//  Annotation.swift
//  CobrowsePOC
//
//  Cobrowse annotations — общий протокол (iOS-сторона).
//
//  Зеркало web-модуля `web-agent/lib/anno.ts`. Формат на проводе (JSON) обязан
//  совпадать байт-в-байт по ключам, FNV-хэш и палитра цветов — тоже, иначе iOS
//  и web не поймут друг друга / цвет оператора разъедется между платформами.
//  Любая правка схемы здесь → синхронная правка в anno.ts.
//
//  Файл сознательно UIKit-free — это чистая модель (Codable + координаты +
//  цвета + reducer). Конверсия hex→UIColor и отрисовка живут в overlay-слое
//  (ANNO-1/ANNO-2). SDK остаётся транспорт-нейтральным: аннотации — «просто
//  байты» поверх CobrowseTransport.
//
//  См. docs/annotations-plan.md (§4 координаты, §5 протокол, §6 мульти-юзер).
//

import Foundation
import CoreGraphics

// MARK: - Константы протокола

public enum AnnoProtocol {
    /// LiveKit data topic для всех аннотационных сообщений.
    public static let topic = "cobrowse.anno"
    /// Версия протокола. Ломающие изменения инкрементят это число.
    public static let version = 1
    /// Максимальная длина текстовой аннотации (символов).
    public static let maxTextLen = 200
}

// MARK: - Wire-типы (значения строковые для forward-compat — как в TS union'ах)

public typealias AnnoPoint = [Double] // [nx, ny], каждая в [0..1]

/// Сообщение на проводе. Геометрия — в нормализованных координатах.
/// Опциональные поля присутствуют в зависимости от `op`/`kind` и при кодировании
/// nil-поля опускаются (как undefined в JSON.stringify).
public struct AnnoMsg: Codable, Equatable {
    public var v: Int
    public var op: String          // add|append|end|remove|clear|pointer|sync-req|sync-state
    public var author: String      // participant identity
    public var ts: Double
    public var id: String?         // "author:counter"
    public var kind: String?       // path|arrow|text|shape
    public var color: String?      // hex "#ff375f"
    public var w: Double?          // нормализованная толщина линии
    public var pts: [AnnoPoint]?   // path
    public var from: AnnoPoint?    // arrow/shape
    public var to: AnnoPoint?      // arrow/shape
    public var at: AnnoPoint?      // text/pointer
    public var text: String?       // text
    public var size: Double?       // нормализованный кегль
    public var shape: String?      // rect|ellipse
    public var fill: Bool?         // shape
    public var scope: String?      // clear: own|all
    public var items: [Annotation]? // sync-state

    public init(v: Int = AnnoProtocol.version,
                op: String,
                author: String,
                ts: Double,
                id: String? = nil,
                kind: String? = nil,
                color: String? = nil,
                w: Double? = nil,
                pts: [AnnoPoint]? = nil,
                from: AnnoPoint? = nil,
                to: AnnoPoint? = nil,
                at: AnnoPoint? = nil,
                text: String? = nil,
                size: Double? = nil,
                shape: String? = nil,
                fill: Bool? = nil,
                scope: String? = nil,
                items: [Annotation]? = nil) {
        self.v = v; self.op = op; self.author = author; self.ts = ts
        self.id = id; self.kind = kind; self.color = color; self.w = w
        self.pts = pts; self.from = from; self.to = to; self.at = at
        self.text = text; self.size = size; self.shape = shape; self.fill = fill
        self.scope = scope; self.items = items
    }
}

/// Сохранённая аннотация в сторе (персистентная, без эфемерных указок).
public struct Annotation: Codable, Equatable {
    public var id: String
    public var author: String
    public var kind: String
    public var color: String
    public var ts: Double
    public var w: Double?
    public var pts: [AnnoPoint]?
    public var from: AnnoPoint?
    public var to: AnnoPoint?
    public var at: AnnoPoint?
    public var text: String?
    public var size: Double?
    public var shape: String?
    public var fill: Bool?

    public init(id: String, author: String, kind: String, color: String, ts: Double,
                w: Double? = nil, pts: [AnnoPoint]? = nil, from: AnnoPoint? = nil,
                to: AnnoPoint? = nil, at: AnnoPoint? = nil, text: String? = nil,
                size: Double? = nil, shape: String? = nil, fill: Bool? = nil) {
        self.id = id; self.author = author; self.kind = kind; self.color = color; self.ts = ts
        self.w = w; self.pts = pts; self.from = from; self.to = to; self.at = at
        self.text = text; self.size = size; self.shape = shape; self.fill = fill
    }
}

/// Эфемерная указка одного оператора.
public struct AnnoPointer: Equatable {
    public var author: String
    public var color: String
    public var at: AnnoPoint
    public var ts: Double
}

/// Эфемерный клик указкой — расходящееся кольцо в точке нажатия.
/// Форма совпадает с указкой; отличаются время жизни и рендер (зеркало `Click` в anno.ts).
public typealias AnnoClick = AnnoPointer

/// Параметры анимации клика. Единый источник для стора (истечение) и рендера.
public enum AnnoClickAnim {
    /// Время жизни анимации, мс. Должно совпадать с CLICK_TTL_MS в anno.ts.
    public static let ttlMs: Double = 600

    /// Прогресс 0→1: радиус растёт, непрозрачность падает.
    public static func progress(ageMs: Double) -> Double {
        let p = ageMs / ttlMs
        return p < 0 ? 0 : (p > 1 ? 1 : p)
    }
}

// MARK: - Кодек

public enum AnnoCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Стабильный порядок ключей не важен (обе стороны парсят по имени),
        // но включаем для детерминизма при отладке/тестах.
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    /// Сериализовать сообщение в Data для sendData.
    public static func encode(_ msg: AnnoMsg) -> Data? {
        try? encoder.encode(msg)
    }

    /// Разобрать Data в сообщение. Возвращает nil на битом JSON или несовпадении
    /// версии — вызывающий молча игнорирует такие пакеты.
    public static func decode(_ data: Data) -> AnnoMsg? {
        guard let msg = try? decoder.decode(AnnoMsg.self, from: data) else { return nil }
        guard msg.v == AnnoProtocol.version else { return nil }
        return msg
    }
}

// MARK: - Координаты (letterbox object-fit: contain)

/// Контент-бокс видео (реальные пиксели без letterbox-полос).
public struct ContentRect {
    public var x: CGFloat
    public var y: CGFloat
    public var w: CGFloat
    public var h: CGFloat
    public init(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public enum AnnoCoords {
    /// Контент-бокс видео внутри `element` при object-fit: contain.
    /// `vidW/vidH` — интринсик-размеры кадра. Для iOS-overlay (окно = кадр)
    /// element обычно = bounds окна, vid = dimensions трека.
    public static func contentRect(inElement element: CGRect,
                                   videoWidth vidW: CGFloat,
                                   videoHeight vidH: CGFloat) -> ContentRect {
        guard vidW > 0, vidH > 0, element.width > 0, element.height > 0 else {
            return ContentRect(x: element.minX, y: element.minY, w: element.width, h: element.height)
        }
        let scale = min(element.width / vidW, element.height / vidH)
        let w = vidW * scale
        let h = vidH * scale
        return ContentRect(x: element.minX + (element.width - w) / 2,
                           y: element.minY + (element.height - h) / 2,
                           w: w, h: h)
    }

    /// Нормализованная точка → пиксельная координата внутри контент-бокса.
    /// Основной путь на клиенте: рендер входящих аннотаций.
    public static func point(fromNormalized p: AnnoPoint, in rect: ContentRect) -> CGPoint {
        guard p.count == 2 else { return CGPoint(x: rect.x, y: rect.y) }
        return CGPoint(x: rect.x + clamp01(CGFloat(p[0])) * rect.w,
                       y: rect.y + clamp01(CGFloat(p[1])) * rect.h)
    }

    /// Пиксельная координата → нормализованная точка. Возвращает nil, если точка
    /// вне контент-бокса (симметрично web `toNormalized`).
    public static func normalized(fromPoint pt: CGPoint, in rect: ContentRect) -> AnnoPoint? {
        guard rect.w > 0, rect.h > 0 else { return nil }
        let nx = (pt.x - rect.x) / rect.w
        let ny = (pt.y - rect.y) / rect.h
        if nx < 0 || nx > 1 || ny < 0 || ny > 1 { return nil }
        return [Double(clamp01(nx)), Double(clamp01(ny))]
    }

    private static func clamp01(_ v: CGFloat) -> CGFloat { v < 0 ? 0 : (v > 1 ? 1 : v) }
}

// MARK: - Цвета по автору (детерминированно, паритет с anno.ts)

public enum AnnoColor {
    /// Палитра из 8 контрастных цветов (= MAX_AGENTS_PER_SESSION). Порядок обязан
    /// совпадать с web `PALETTE`, иначе цвет оператора разъедется между платформами.
    public static let palette: [String] = [
        "#ff375f", // красно-розовый
        "#0a84ff", // синий
        "#30d158", // зелёный
        "#ff9f0a", // оранжевый
        "#bf5af2", // фиолетовый
        "#64d2ff", // голубой
        "#ffd60a", // жёлтый
        "#ff6482", // коралловый
    ]

    /// FNV-1a 32-бит по UTF-8 байтам. Обязан совпадать с web `fnv1a32`
    /// (та же offset basis, тот же prime, uint32-overflow-семантика).
    public static func fnv1a32(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5 // 2166136261
        for b in Array(s.utf8) {
            hash ^= UInt32(b)
            hash = hash &* 0x0100_0193 // *16777619 с wrap-around (как >>>0 в JS)
        }
        return hash
    }

    /// Детерминированный цвет оператора по его identity.
    public static func hex(forIdentity identity: String) -> String {
        palette[Int(fnv1a32(identity) % UInt32(palette.count))]
    }
}

// MARK: - Состояние и reducer (мёрж входящих ops)

/// Канонический стор аннотаций на клиенте. Мутируется входящими сообщениями,
/// отвечает за snapshot (sync-state) и очистку. Семантика зеркалит anno.ts.
/// НЕ thread-safe — обновлять с main actor (как и рендер overlay).
public final class AnnoState {
    public private(set) var items: [String: Annotation] = [:] // персистентные, по id
    public private(set) var pointers: [String: AnnoPointer] = [:] // эфемерные, по автору
    /// Эфемерные клики указкой. Ключ `author:ts` — их может быть несколько одновременно.
    public private(set) var clicks: [String: AnnoClick] = [:]

    public init() {}

    /// Применить входящее сообщение.
    /// - Parameter isAgent: гейт прав (§6.4). Если задан и вернул false — op
    ///   игнорируется (клиент писать не может). Автор не может трогать чужие id.
    public func apply(_ msg: AnnoMsg, isAgent: ((String) -> Bool)? = nil) {
        if let isAgent, !isAgent(msg.author) { return }

        switch msg.op {
        case "add":
            guard let id = msg.id, let kind = msg.kind else { return }
            items[id] = Annotation(
                id: id, author: msg.author, kind: kind,
                color: msg.color ?? AnnoColor.hex(forIdentity: msg.author),
                ts: msg.ts, w: msg.w, pts: msg.pts, from: msg.from, to: msg.to,
                at: msg.at, text: msg.text.map(clampText), size: msg.size,
                shape: msg.shape, fill: msg.fill
            )

        case "append":
            guard let id = msg.id, var a = items[id], a.author == msg.author else { return }
            if a.kind == "path", let pts = msg.pts { a.pts = (a.pts ?? []) + pts }
            if let to = msg.to { a.to = to } // arrow/shape тянут второй угол
            if let text = msg.text { a.text = clampText(text) }
            a.ts = msg.ts
            items[id] = a

        case "end":
            guard let id = msg.id, var a = items[id], a.author == msg.author else { return }
            if let pts = msg.pts { a.pts = pts }
            if let from = msg.from { a.from = from }
            if let to = msg.to { a.to = to }
            if let at = msg.at { a.at = at }
            if let text = msg.text { a.text = clampText(text) }
            a.ts = msg.ts
            items[id] = a

        case "remove":
            guard let id = msg.id, let a = items[id], a.author == msg.author else { return }
            items.removeValue(forKey: id) // только своё

        case "clear":
            if msg.scope == "all" {
                items.removeAll()
                pointers.removeAll()
                clicks.removeAll()
            } else {
                items = items.filter { $0.value.author != msg.author }
                pointers.removeValue(forKey: msg.author)
                clicks = clicks.filter { $0.value.author != msg.author }
            }

        case "pointer":
            guard let at = msg.at else { return }
            pointers[msg.author] = AnnoPointer(
                author: msg.author,
                color: msg.color ?? AnnoColor.hex(forIdentity: msg.author),
                at: at, ts: msg.ts
            )

        case "click":
            guard let at = msg.at else { return }
            // Ключ с ts: несколько кликов подряд сосуществуют и гаснут каждый свой.
            clicks["\(msg.author):\(msg.ts)"] = AnnoClick(
                author: msg.author,
                color: msg.color ?? AnnoColor.hex(forIdentity: msg.author),
                at: at, ts: msg.ts
            )

        case "sync-state":
            guard let incoming = msg.items else { return }
            for it in incoming { items[it.id] = it }

        case "sync-req":
            // Обрабатывается на транспортном слое (клиент отвечает sync-state
            // адресно запросившему). Здесь состояние не меняется.
            break

        default:
            break // неизвестный op — forward-compat, игнорируем
        }
    }

    /// Убрать все аннотации ушедшего оператора (по participantDisconnected).
    public func removeAuthor(_ author: String) {
        items = items.filter { $0.value.author != author }
        pointers.removeValue(forKey: author)
        clicks = clicks.filter { $0.value.author != author }
    }

    /// Полная очистка (снятие overlay по .ended/.error).
    public func clearAll() {
        items.removeAll()
        pointers.removeAll()
        clicks.removeAll()
    }

    /// Снять протухшие указки (не обновлялись дольше ttl, мс).
    public func expirePointers(now: Double, ttlMs: Double = 1000) {
        pointers = pointers.filter { now - $0.value.ts <= ttlMs }
    }

    /// Снять отыгравшие клики.
    public func expireClicks(now: Double, ttlMs: Double = AnnoClickAnim.ttlMs) {
        clicks = clicks.filter { now - $0.value.ts <= ttlMs }
    }

    /// Полный снапшот персистентных аннотаций — тело sync-state.
    public func snapshot() -> [Annotation] {
        Array(items.values)
    }

    private func clampText(_ t: String) -> String {
        t.count > AnnoProtocol.maxTextLen ? String(t.prefix(AnnoProtocol.maxTextLen)) : t
    }
}

// MARK: - Хелперы отправителя

/// Генератор стабильных id аннотаций в рамках автора: "agent-ab12:37".
public final class AnnoIdGen {
    private let author: String
    private var n = 0
    public init(author: String) { self.author = author }
    public func next() -> String { n += 1; return "\(author):\(n)" }
}

public extension AnnoProtocol {
    /// true — слать надёжно (reliable); false — lossy (best-effort).
    static func isReliable(op: String) -> Bool {
        switch op {
        case "pointer", "append": return false // высокочастотные, потеря незаметна
        default: return true                    // add/end/remove/clear/sync-* критичны
        }
    }
}
