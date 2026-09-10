//
//  ContentView.swift
//  CobrowseTestApp
//
//  TabView с 5 экранами для тестирования screen share + REC-индикатор в верхнем
//  safe-area (виден на любом табе) + floating шестерёнка настроек видео
//  (в верхнем-правом углу, тоже поверх всех табов) + перетаскиваемая плавающая
//  кнопка чата поддержки (SupportFAB). Все кнопки-оверлеи живут здесь, а не в
//  отдельных табах, чтобы поведение было консистентным везде.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var client: CobrowseClient
    @State private var showVideoSettings = false
    @State private var showSupportChat = false
    /// Позиция FAB чата. Живёт здесь, а не в SupportFAB: кнопка монтируется
    /// условно и прячется при открытом чате — локальный @State сбрасывался бы.
    @State private var fabPosition: CGPoint?

    // Менеджер overlay-окна аннотаций. @State держит инстанс между перерисовками.
    @State private var overlayHost = AnnotationOverlayHost()

    var body: some View {
        ZStack(alignment: .top) {
            TabView {
                SessionTab()
                    .tabItem { Label("Сессия", systemImage: "dot.radiowaves.left.and.right") }

                AnimationTab()
                    .tabItem { Label("Движение", systemImage: "waveform.path.ecg") }

                FormsTab()
                    .tabItem { Label("Формы", systemImage: "square.and.pencil") }

                CanvasTab()
                    .tabItem { Label("Рисовать", systemImage: "scribble.variable") }

                ZooTab()
                    .tabItem { Label("Всякое", systemImage: "square.grid.2x2") }
            }

            // Постоянный REC-индикатор в центре сверху.
            RecBadge()
                .padding(.top, 8)
        }
        // Шестерёнка настроек — в правом верхнем углу поверх всех табов.
        // Только когда есть живой трек, который имеет смысл перенастраивать
        // (в .reconnecting republish кинет .notStreaming, так что скрываем).
        .overlay(alignment: .topTrailing) {
            if isStreaming {
                VideoSettingsButton {
                    showVideoSettings = true
                }
                .padding(.top, 8)
                .padding(.trailing, 12)
                // На iOS 16+ transitions работают из коробки, лёгкий fade
                // избавляет от резкого моргания при старте/стопе сессии.
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isStreaming)
        // Плавающая кнопка чата поддержки — только при активной сессии
        // (streaming/reconnecting, как overlay аннотаций). Пока открыт экран
        // чата (cover или push из Настроек), кнопка прячется сама по chat.isOpen.
        .overlay {
            if overlayVisible {
                SupportFAB(chat: client.chat, position: $fabPosition) {
                    showSupportChat = true
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: overlayVisible)
        // Cover, а не sheet: «Назад» возвращает ровно туда, где был пользователь,
        // на любом табе и на любой глубине навигации.
        .fullScreenCover(isPresented: $showSupportChat) {
            NavigationStack {
                SupportChatView()
            }
            .environmentObject(client)
        }
        .sheet(isPresented: $showVideoSettings) {
            VideoSettingsSheet(current: client.screenShareOptions)
                .environmentObject(client)
        }
        // Монтаж/демонтаж overlay-окна аннотаций по состоянию сессии.
        // Видим при активной сессии (.streaming/.reconnecting), снимаем и чистим
        // сторы аннотаций и чата в терминальных состояниях (.ended/.error/.idle).
        .onChange(of: overlayVisible, initial: true) { _, visible in
            if visible {
                overlayHost.show(store: client.annotations)
            } else {
                overlayHost.hide()
                client.annotations.reset()
                client.chat.reset()   // истории чата нет — живёт в рамках сессии
            }
        }
    }

    private var isStreaming: Bool {
        if case .streaming = client.state { return true }
        return false
    }

    /// Overlay виден при активной сессии — и в streaming, и в reconnecting
    /// (реконнект идёт в ту же комнату, аннотации не сбрасываем).
    private var overlayVisible: Bool {
        switch client.state {
        case .streaming, .reconnecting: return true
        default: return false
        }
    }
}

// MARK: - Floating video settings button

private struct VideoSettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.black.opacity(0.75)))
        }
        .accessibilityLabel("Настройки видео")
    }
}

// MARK: - REC badge (виден всегда, когда идёт стрим)

private struct RecBadge: View {
    @EnvironmentObject var client: CobrowseClient
    @State private var pulse = false

    var body: some View {
        Group {
            switch client.state {
            case .streaming(let code):
                recCapsule(color: .red, pulse: true) {
                    Text("REC · \(code)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white)
                }

            case .reconnecting(let code):
                // Жёлтый — сессия жива, но нестабильна. Код всё ещё виден,
                // потому что реконнект идёт в ту же комнату, оператор не уходит.
                recCapsule(color: .yellow, pulse: true) {
                    HStack(spacing: 6) {
                        Text("↻ \(code)")
                            .font(.caption.monospacedDigit().bold())
                        Text("восстанавливаем")
                            .font(.caption2)
                            .opacity(0.9)
                    }
                    .foregroundStyle(.black)
                }

            case .connecting, .requestingConsent:
                Text("Подключение…")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.orange.opacity(0.85)))
                    .foregroundStyle(.white)

            case .error(let msg):
                Text("⚠ \(msg)")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.red.opacity(0.85)))
                    .foregroundStyle(.white)

            case .idle, .ended:
                EmptyView()
            }
        }
    }

    /// Общая форма REC-индикатора: пульсирующая цветная точка + произвольный
    /// контент справа. Используется в двух вариантах — активный стрим (red)
    /// и реконнект (yellow).
    @ViewBuilder
    private func recCapsule<Content: View>(color: Color,
                                           pulse startPulse: Bool,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                           value: pulse)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.75)))
        .onAppear { if startPulse { pulse = true } }
    }
}

#Preview {
    ContentView()
        .environmentObject(CobrowseClient(backendURL: AppConfig.backendURL))
}
