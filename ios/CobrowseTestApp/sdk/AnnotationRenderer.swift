//
//  AnnotationRenderer.swift
//  CobrowsePOC
//
//  SwiftUI Canvas-рендер операторских аннотаций из AnnotationStore.
//  Рисует все типы (path/arrow/text/shape) + эфемерную указку с плавным
//  угасанием. Нормализованные координаты → пиксели через AnnoCoords.
//
//  На клиенте кадр ReplayKit = окно приложения (тот же aspect), поэтому
//  letterbox'а нет и контент-бокс = полный bounds окна.
//
//  См. docs/annotations-plan.md (§4 координаты, §7 типы, §8 iOS overlay).
//

import SwiftUI

// MARK: - Параметры угасания указки

private enum PointerFade {
    /// До этого возраста (мс с последнего апдейта) указка на полной непрозрачности.
    static let holdMs: Double = 400
    /// К этому возрасту указка полностью прозрачна. Совпадает с TTL в
    /// AnnotationStore, который её и удаляет — так фейд и удаление согласованы.
    static let ttlMs: Double = 1000

    /// Непрозрачность указки по возрасту: 1 пока свежая, линейно к 0 к ttl.
    static func opacity(age: Double) -> Double {
        if age <= holdMs { return 1 }
        if age >= ttlMs { return 0 }
        return 1 - (age - holdMs) / (ttlMs - holdMs)
    }
}

// MARK: - Canvas-рендер

struct AnnotationCanvasView: View {
    @ObservedObject var store: AnnotationStore

    var body: some View {
        Canvas { ctx, size in
            let rect = ContentRect(x: 0, y: 0, w: size.width, h: size.height)
            let shortSide = min(size.width, size.height)

            for a in store.annotations {
                draw(a, in: &ctx, rect: rect, shortSide: shortSide)
            }

            // now читаем в момент отрисовки; стор публикует снапшоты ~10 раз/с,
            // пока есть указки, поэтому фейд обновляется без отдельной анимации.
            let nowMs = Date().timeIntervalSince1970 * 1000
            for p in store.pointers {
                drawPointer(p, in: &ctx, rect: rect, shortSide: shortSide, nowMs: nowMs)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: Персистентные аннотации

    private func draw(_ a: Annotation, in ctx: inout GraphicsContext, rect: ContentRect, shortSide: CGFloat) {
        let color = Color(annoHex: a.color)
        let lineW = max(1, CGFloat(a.w ?? 0.006) * shortSide)

        switch a.kind {
        case "path":
            guard let pts = a.pts, !pts.isEmpty else { return }
            let cg = pts.map { AnnoCoords.point(fromNormalized: $0, in: rect) }
            var path = Path()
            path.move(to: cg[0])
            for pt in cg.dropFirst() { path.addLine(to: pt) }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round))

        case "arrow":
            guard let f = a.from, let t = a.to else { return }
            let p0 = AnnoCoords.point(fromNormalized: f, in: rect)
            let p1 = AnnoCoords.point(fromNormalized: t, in: rect)
            var shaft = Path(); shaft.move(to: p0); shaft.addLine(to: p1)
            ctx.stroke(shaft, with: .color(color),
                       style: StrokeStyle(lineWidth: lineW, lineCap: .round))
            let head = arrowHead(from: p0, to: p1, size: max(10, lineW * 3.5))
            ctx.stroke(head, with: .color(color),
                       style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round))

        case "shape":
            guard let f = a.from, let t = a.to else { return }
            let p0 = AnnoCoords.point(fromNormalized: f, in: rect)
            let p1 = AnnoCoords.point(fromNormalized: t, in: rect)
            let r = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                           width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            let path = (a.shape == "ellipse") ? Path(ellipseIn: r) : Path(roundedRect: r, cornerRadius: 3)
            if a.fill == true { ctx.fill(path, with: .color(color.opacity(0.20))) }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineW))

        case "text":
            guard let at = a.at, let text = a.text, !text.isEmpty else { return }
            let origin = AnnoCoords.point(fromNormalized: at, in: rect)
            let fontSize = max(11, CGFloat(a.size ?? 0.035) * shortSide)
            let resolved = ctx.resolve(
                Text(text).font(.system(size: fontSize, weight: .semibold)).foregroundColor(color)
            )
            ctx.draw(resolved, at: origin, anchor: .topLeading)

        default:
            break   // неизвестный kind — forward-compat, пропускаем
        }
    }

    // MARK: Указка (с угасанием)

    private func drawPointer(_ p: AnnoPointer, in ctx: inout GraphicsContext, rect: ContentRect, shortSide: CGFloat, nowMs: Double) {
        let opacity = PointerFade.opacity(age: nowMs - p.ts)
        guard opacity > 0 else { return }

        let c = AnnoCoords.point(fromNormalized: p.at, in: rect)
        let color = Color(annoHex: p.color)
        let r = max(6, shortSide * 0.018)
        // гало + ядро — читается поверх любого фона
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                 with: .color(color.opacity(0.25 * opacity)))
        let cr = r * 0.5
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - cr, y: c.y - cr, width: 2 * cr, height: 2 * cr)),
                 with: .color(color.opacity(opacity)))
    }

    // MARK: Геометрия наконечника стрелки

    private func arrowHead(from p0: CGPoint, to p1: CGPoint, size: CGFloat) -> Path {
        let angle = atan2(p1.y - p0.y, p1.x - p0.x)
        let a1 = angle + .pi * 5.0 / 6.0
        let a2 = angle - .pi * 5.0 / 6.0
        var p = Path()
        p.move(to: p1)
        p.addLine(to: CGPoint(x: p1.x + cos(a1) * size, y: p1.y + sin(a1) * size))
        p.move(to: p1)
        p.addLine(to: CGPoint(x: p1.x + cos(a2) * size, y: p1.y + sin(a2) * size))
        return p
    }
}

// MARK: - hex → Color

extension Color {
    /// Инициализация из hex-строки палитры аннотаций ("#rrggbb" или "#rrggbbaa").
    /// Fallback — пурпурный, чтобы битый цвет был заметен, а не невидим.
    init(annoHex hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((v & 0xFF0000) >> 16) / 255
            g = Double((v & 0x00FF00) >> 8) / 255
            b = Double(v & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((v & 0xFF000000) >> 24) / 255
            g = Double((v & 0x00FF0000) >> 16) / 255
            b = Double((v & 0x0000FF00) >> 8) / 255
            a = Double(v & 0x0000_00FF) / 255
        default:
            r = 1; g = 0; b = 1; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
