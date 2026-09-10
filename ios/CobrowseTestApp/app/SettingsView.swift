//
//  SettingsView.swift
//  CobrowseTestApp
//
//  «Глубокие» настройки демо-приложения — второй путь к чату поддержки:
//  Всякое → Настройки → Помощь и поддержка → Чат с поддержкой. Остальные
//  пункты — правдоподобная бутафория, чтобы экран не выглядел заглушкой
//  и заодно давал контент для проверки стрима (тогглы, раскрывающиеся FAQ).
//

import SwiftUI

struct SettingsView: View {
    @State private var pushEnabled = true
    @State private var emailDigest = false

    var body: some View {
        List {
            Section("Профиль") {
                LabeledContent("Имя", value: "Иван Иванов")
                LabeledContent("Телефон", value: "+7 ••• ••• 12-34")
            }

            Section("Уведомления") {
                Toggle("Push-уведомления", isOn: $pushEnabled)
                Toggle("Дайджест на почту", isOn: $emailDigest)
            }

            Section {
                NavigationLink {
                    HelpView()
                } label: {
                    Label("Помощь и поддержка", systemImage: "questionmark.circle")
                }
            }

            Section("О приложении") {
                LabeledContent("Версия", value: "1.0 (PoC)")
            }
        }
        .navigationTitle("Настройки")
    }
}

// MARK: - Помощь и поддержка

struct HelpView: View {
    var body: some View {
        List {
            Section("Частые вопросы") {
                FAQItem(
                    question: "Как начать сессию с оператором?",
                    answer: "Откройте вкладку «Сессия», запустите сессию и продиктуйте оператору код с экрана."
                )
                FAQItem(
                    question: "Что видит оператор?",
                    answer: "Только экран этого приложения, пока идёт сессия. Индикатор REC сверху показывает, что трансляция активна."
                )
                FAQItem(
                    question: "Как завершить сессию?",
                    answer: "Нажмите «Завершить сессию» на вкладке «Сессия» — трансляция остановится сразу."
                )
            }

            Section {
                NavigationLink {
                    SupportChatView()
                } label: {
                    Label("Чат с поддержкой", systemImage: "bubble.left.and.bubble.right")
                }
            } footer: {
                Text("Во время сессии с оператором чат также доступен по плавающей кнопке.")
            }
        }
        .navigationTitle("Помощь и поддержка")
    }
}

private struct FAQItem: View {
    let question: String
    let answer: String

    var body: some View {
        DisclosureGroup(question) {
            Text(answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(CobrowseClient(backendURL: AppConfig.backendURL))
    }
}
