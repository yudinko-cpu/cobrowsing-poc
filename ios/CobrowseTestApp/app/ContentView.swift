//
//  ContentView.swift
//  CobrowseTestApp
//
//  TabView с 5 экранами для тестирования screen share + REC-индикатор
//  в safe-area, который виден на любом табе.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var client: CobrowseClient

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

            // Постоянный индикатор шаринга поверх всех табов.
            RecBadge()
                .padding(.top, 8)
        }
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
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .opacity(pulse ? 0.3 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: pulse)
                    Text("REC · \(code)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.75)))
                .onAppear { pulse = true }

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
}

#Preview {
    ContentView()
        .environmentObject(CobrowseClient(backendURL: AppConfig.backendURL))
}
