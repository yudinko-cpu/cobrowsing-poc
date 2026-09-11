//
//  SupportFAB.swift
//  CobrowseTestApp
//
//  Плавающая кнопка чата поддержки. Полупрозрачный круг, который клиент может
//  перетащить в любое место экрана, чтобы он не мешал интерфейсу; после
//  отпускания прилипает к ближайшему боковому краю. Тап открывает чат.
//  Поверх кружка — бейдж непрочитанных и капсула «оператор печатает». Рядом —
//  стопка превью последних сообщений (PreviewStack): читать ответы оператора
//  можно, не открывая чат; тап по пузырьку «лопает» его.
//
//  Живёт в SwiftUI-иерархии ContentView (overlay поверх всех табов), а не в
//  overlay-окне аннотаций — то окно pass-through (hitTest → nil) и не может
//  принимать касания.
//
//  Позиция хранится снаружи (@Binding в ContentView): FAB монтируется условно
//  (только при активной сессии) и прячется, пока открыт экран чата, — локальный
//  @State сбрасывался бы при каждом размонтировании.
//

import SwiftUI

struct SupportFAB: View {
    /// Наблюдаем стор напрямую: `client.chat` — вложенный ObservableObject,
    /// его изменения не проходят через `client.objectWillChange`.
    @ObservedObject var chat: ChatStore
    /// Центр кнопки в координатах overlay. nil — дефолт (правый нижний угол).
    @Binding var position: CGPoint?
    let onTap: () -> Void

    /// Текущий сдвиг во время перетаскивания. @GestureState сам обнуляется,
    /// если жест отменён системой (звонок, алерт) — кнопка не «зависнет» со сдвигом.
    @GestureState private var drag: CGSize = .zero

    private let size: CGFloat = 56
    private let margin: CGFloat = 12
    /// Сдвиг меньше этого — тап, а не перетаскивание.
    private let tapSlop: CGFloat = 8
    /// REC-бейдж и шестерёнка настроек видео живут сверху.
    private let topClearance: CGFloat = 52
    /// Таб-бар снизу (на iOS 26 плавающий) — с запасом.
    private let bottomClearance: CGFloat = 80
    /// Зазор между кнопкой и стопкой превью. Под кнопкой больше — там
    /// выскакивает капсула «печатает».
    private let previewGapAbove: CGFloat = 8
    private let previewGapBelow: CGFloat = 18
    /// Потолок ширины пузырька: не заграждать экран, но вмещать фразу.
    private let previewMaxWidth: CGFloat = 260

    var body: some View {
        // GeometryReader сам не хит-тестится: касания вне кружка проходят в TabView.
        GeometryReader { geo in
            if !chat.isOpen {
                let bounds = allowedRect(in: geo.size)
                // Клампим при каждом рендере: сохранённая позиция могла выйти за
                // экран после поворота / смены размеров.
                let base = clamp(position ?? CGPoint(x: bounds.maxX, y: bounds.maxY), to: bounds)
                let shown = clamp(CGPoint(x: base.x + drag.width, y: base.y + drag.height), to: bounds)
                let onLeft = shown.x < bounds.midX
                let below = shown.y < bounds.midY

                // Превью сообщений — стопкой рядом с кнопкой, в сторону центра
                // экрана: над кнопкой (под ней, если кнопка в верхней половине),
                // прижаты к её краю. Якорь — невидимый квадрат размером с кнопку
                // в той же точке: alignmentGuide выносит стопку за его границу,
                // а .position двигает её вместе с кнопкой, в том числе во время drag.
                if !chat.previews.isEmpty {
                    Color.clear
                        .frame(width: size, height: size)
                        .overlay(alignment: previewAlignment(onLeft: onLeft, below: below)) {
                            PreviewStack(
                                previews: chat.previews,
                                onLeft: onLeft,
                                below: below,
                                width: min(previewMaxWidth, geo.size.width - size - margin * 2),
                                onPop: { chat.dismissPreview(id: $0.id) }
                            )
                            .alignmentGuide(below ? .bottom : .top) { d in
                                below ? d[.top] - previewGapBelow : d[.bottom] + previewGapAbove
                            }
                        }
                        .position(shown)
                        .transition(.opacity)
                }

                fab
                    // Один жест на тап и drag: тап и DragGesture на одном view
                    // конкурируют, а minimumDistance: 0 + порог по сдвигу
                    // детерминирован. Жест — на самом кружке (до .position),
                    // иначе прозрачная область вокруг ничего не ловит.
                    //
                    // coordinateSpace: .global обязателен. В .local система
                    // координат жеста едет вместе с кружком, который мы сами
                    // двигаем через .position: на каждом событии translation
                    // «обнуляется», кнопка мечется между старой и новой точкой
                    // и еле ползёт за пальцем. В глобальных координатах сдвиг
                    // считается от неподвижного начала касания.
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .updating($drag) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                let t = value.translation
                                if hypot(t.width, t.height) < tapSlop {
                                    onTap()
                                    return
                                }
                                let released = clamp(CGPoint(x: base.x + t.width, y: base.y + t.height), to: bounds)
                                // Сначала без анимации фиксируем базу в точке отпускания:
                                // @GestureState в этом же апдейте сбросится в .zero, и
                                // картинка не дёрнется. Потом — анимированное прилипание
                                // к краю уже следующим апдейтом.
                                position = released
                                let target = snapToEdge(released, in: bounds)
                                Task { @MainActor in
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        position = target
                                    }
                                }
                            }
                    )
                    .position(shown)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chat.isOpen)
    }

    // MARK: - Вид

    private var isTyping: Bool { !chat.typing.isEmpty }

    private var fab: some View {
        Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            // Полупрозрачно — в стиле VideoSettingsButton, но заметнее на светлом.
            .background(Circle().fill(.black.opacity(0.55)))
            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .overlay(alignment: .topTrailing) {
                if chat.unreadCount > 0 {
                    Text(chat.unreadCount > 99 ? "99+" : "\(chat.unreadCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(.red))
                        .offset(x: 4, y: -4)
                }
            }
            // «Оператор печатает»: белая капсула с бегущими точками у нижнего
            // края — как всплывающий пузырь ответа. Бейдж непрочитанных при
            // этом остаётся сверху справа, за место они не спорят.
            .overlay(alignment: .bottom) {
                if isTyping {
                    TypingDots(color: .black.opacity(0.75), dotSize: 5, spacing: 2.5)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white))
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        .offset(y: 7)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTyping)
            .contentShape(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Чат с поддержкой")
            .accessibilityValue(accessibilityValueText)
            .accessibilityHint("Открывает чат. Перетащите, чтобы переместить кнопку.")
            .accessibilityAddTraits(.isButton)
            // VoiceOver активирует элемент двойным тапом — DragGesture его не
            // получает, поэтому отдельное default-действие.
            .accessibilityAction { onTap() }
    }

    private var accessibilityValueText: String {
        var parts: [String] = []
        if chat.unreadCount > 0 { parts.append("\(chat.unreadCount) непрочитанных") }
        if isTyping { parts.append("оператор печатает") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Геометрия

    /// Допустимые центры кнопки: с полями от краёв и отступами от REC-бейджа
    /// сверху и таб-бара снизу.
    private func allowedRect(in container: CGSize) -> CGRect {
        let r = size / 2
        let minX = margin + r
        let maxX = max(minX, container.width - margin - r)
        let minY = topClearance + r
        let maxY = max(minY, container.height - bottomClearance - r)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX),
                y: min(max(p.y, r.minY), r.maxY))
    }

    /// Прилипание к ближайшему боковому краю; вертикаль сохраняется.
    private func snapToEdge(_ p: CGPoint, in r: CGRect) -> CGPoint {
        CGPoint(x: p.x < r.midX ? r.minX : r.maxX, y: p.y)
    }

    /// Угол якоря, к которому прижата стопка превью: край кнопки, обращённый
    /// к центру экрана, и та сторона, где больше места.
    private func previewAlignment(onLeft: Bool, below: Bool) -> Alignment {
        switch (onLeft, below) {
        case (true, false):  return .topLeading
        case (false, false): return .topTrailing
        case (true, true):   return .bottomLeading
        case (false, true):  return .bottomTrailing
        }
    }
}

// MARK: - Стопка превью

/// До `ChatStore.maxPreviews` пузырьков с текстом последних входящих. Новые —
/// ближе к кнопке: над кнопкой стопка растёт вверх (старые сверху), под
/// кнопкой — вниз.
private struct PreviewStack: View {
    let previews: [ChatMessage]
    let onLeft: Bool
    let below: Bool
    let width: CGFloat
    let onPop: (ChatMessage) -> Void

    var body: some View {
        let ordered = below ? Array(previews.reversed()) : previews
        VStack(alignment: onLeft ? .leading : .trailing, spacing: 6) {
            ForEach(ordered) { message in
                PreviewBubble(message: message) { onPop(message) }
                    // Появление — «вырастает» из угла у кнопки; исчезновение —
                    // схлопывается туда же: пузырёк лопнул.
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85, anchor: anchor).combined(with: .opacity),
                        removal: .scale(scale: 0.3, anchor: anchor).combined(with: .opacity)
                    ))
            }
        }
        // Фиксированная ширина стопки задаёт предел переноса текста; сами
        // пузырьки обнимают свой текст и прижаты к стороне кнопки. Пустая
        // часть кадра не хит-тестится — экран под ней остаётся кликабельным.
        .frame(width: width, alignment: onLeft ? .leading : .trailing)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: previews)
        // Лёгкая тактильная отдача только когда пузырёк лопнули (число уменьшилось).
        .sensoryFeedback(.impact(weight: .light), trigger: previews.count) { old, new in new < old }
    }

    private var anchor: UnitPoint {
        switch (onLeft, below) {
        case (true, false):  return .bottomLeading
        case (false, false): return .bottomTrailing
        case (true, true):   return .topLeading
        case (false, true):  return .topTrailing
        }
    }
}

/// Один пузырёк: подпись оператора и текст не длиннее трёх строк.
private struct PreviewBubble: View {
    let message: ChatMessage
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.author)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(message.text)
                .font(.subheadline)
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Оператор \(message.author): \(message.text)")
        .accessibilityHint("Нажмите, чтобы скрыть")
        .accessibilityAddTraits(.isButton)
    }
}
