//
//  SupportFAB.swift
//  CobrowseTestApp
//
//  Плавающая кнопка чата поддержки. Полупрозрачный круг, который клиент может
//  перетащить в любое место экрана, чтобы он не мешал интерфейсу; после
//  отпускания прилипает к ближайшему боковому краю. Тап открывает чат.
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

    var body: some View {
        // GeometryReader сам не хит-тестится: касания вне кружка проходят в TabView.
        GeometryReader { geo in
            if !chat.isOpen {
                let bounds = allowedRect(in: geo.size)
                // Клампим при каждом рендере: сохранённая позиция могла выйти за
                // экран после поворота / смены размеров.
                let base = clamp(position ?? CGPoint(x: bounds.maxX, y: bounds.maxY), to: bounds)
                let shown = clamp(CGPoint(x: base.x + drag.width, y: base.y + drag.height), to: bounds)

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
}
