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
                idleView
            case .requestingConsent, .connecting:
                ProgressView("Подключаемся…")
                    .progressViewStyle(.circular)
            case .streaming(let code):
                streamingView(code: code)
            case .ended:
                Text("Сессия завершена")
                    .font(.headline)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Попробовать снова") {
                    Task { try? await client.startSession() }
                }
            }

            Spacer()
        }
        .padding()
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.fill.questionmark")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Нужна помощь оператора?")
                .font(.title2.bold())
            Text("Запустите сессию, и мы соединим вас с поддержкой. Оператор увидит экран этого приложения, чтобы помочь быстрее.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task { try? await client.startSession() }
            } label: {
                Text("Запустить сессию")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func streamingView(code: String) -> some View {
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

            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Идёт запись экрана")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
}
