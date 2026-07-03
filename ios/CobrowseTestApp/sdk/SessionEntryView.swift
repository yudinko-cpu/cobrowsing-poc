//
//  SessionEntryView.swift
//  CobrowsePOC
//
//  SwiftUI экран, который клиент видит после старта сессии:
//  большой 6-значный код для передачи оператору + статус + кнопка завершения.
//

import SwiftUI

public struct SessionEntryView: View {

    @ObservedObject var client: CobrowseClient

    public init(client: CobrowseClient) {
        self.client = client
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            switch client.state {
            case .idle:
                startView(headline: "Нужна помощь оператора?",
                          subtitle: "Запустите сессию, и мы соединим вас с поддержкой. Оператор увидит экран этого приложения, чтобы помочь быстрее.",
                          buttonTitle: "Запустить сессию",
                          icon: "person.fill.questionmark")

            case .requestingConsent, .connecting:
                ProgressView("Подключаемся…")
                    .progressViewStyle(.circular)

            case .streaming(let code):
                streamingView(code: code, isReconnecting: false)

            case .reconnecting(let code):
                streamingView(code: code, isReconnecting: true)

            case .ended:
                startView(headline: "Сессия завершена",
                          subtitle: "Всё готово. Можете начать новую сессию, если снова понадобится помощь.",
                          buttonTitle: "Начать новую сессию",
                          icon: "checkmark.circle")

            case .error(let message):
                errorView(message: message)
            }

            Spacer()
        }
        .padding()
        // Плавно, чтобы переходы (streaming ⇄ reconnecting, ended → connecting)
        // не выглядели как резкая мигрень для пользователя.
        .animation(.easeInOut(duration: 0.2), value: client.state)
    }

    // MARK: - Building blocks

    /// Универсальный "стартовый" вид: используется для .idle и .ended
    /// (обе ситуации — терминальное состояние с одной большой кнопкой).
    private func startView(headline: String,
                           subtitle: String,
                           buttonTitle: String,
                           icon: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(headline)
                .font(.title2.bold())
            Text(subtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task { try? await client.startSession() }
            } label: {
                Text(buttonTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func streamingView(code: String, isReconnecting: Bool) -> some View {
        VStack(spacing: 32) {
            Text("Сообщите этот код оператору")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(code)
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .tracking(8)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                // Слегка гасим код во время реконнекта — визуальный сигнал,
                // что сессия жива, но не полностью стабильна.
                .opacity(isReconnecting ? 0.5 : 1.0)

            if isReconnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Восстанавливаем связь…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Идёт запись экрана")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                Task { await client.stopSession() }
            } label: {
                Text("Завершить сессию")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
            Button {
                Task { try? await client.startSession() }
            } label: {
                Text("Начать заново")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
