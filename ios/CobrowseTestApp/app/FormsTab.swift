//
//  FormsTab.swift
//  CobrowseTestApp
//
//  Поля ввода — проверяет, как рендерится клавиатура, курсор, выделение,
//  форматирование. Плюс поле-приманка (fake credit card) — для будущего
//  тестирования redaction (P1).
//

import SwiftUI

struct FormsTab: View {
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var creditCard = ""
    @State private var cvv = ""
    @State private var date = Date()
    @State private var priority = 1
    @State private var slider: Double = 0.5
    @State private var notifications = true
    @State private var story = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Обычные поля") {
                    LabeledField(label: "Имя", placeholder: "Иван Иванов", text: $name)
                    LabeledField(label: "Email", placeholder: "user@example.com", text: $email, keyboard: .emailAddress)
                }

                // Поля с чувствительными данными — будущая цель для redaction.
                // Помечены `sensitive` тегом, который позже можно ловить и маскировать
                // в custom video capturer.
                Section {
                    LabeledSecure(label: "Пароль", text: $password)
                    LabeledField(
                        label: "Номер карты",
                        placeholder: "1234 5678 9012 3456",
                        text: $creditCard,
                        keyboard: .numberPad
                    )
                    .onChange(of: creditCard) { _, new in
                        creditCard = formatCard(new)
                    }
                    LabeledField(label: "CVV", placeholder: "123", text: $cvv, keyboard: .numberPad)
                } header: {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                        Text("Чувствительные (мишень для redaction P1)")
                    }
                } footer: {
                    Text("Это мок-поля, не отправляются никуда. Используются, чтобы позже проверить, что redaction физически маскирует их в видео-стриме.")
                        .font(.footnote)
                }

                Section("Пикеры и слайдеры") {
                    DatePicker("Дата", selection: $date, displayedComponents: [.date])
                    Picker("Приоритет", selection: $priority) {
                        Text("Низкий").tag(0)
                        Text("Средний").tag(1)
                        Text("Высокий").tag(2)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        Text("Slider: \(String(format: "%.2f", slider))")
                            .font(.caption)
                        Slider(value: $slider, in: 0...1)
                    }
                    Toggle("Уведомления", isOn: $notifications)
                }

                Section("Многострочный текст") {
                    // TextEditor — проверяет прокрутку и рендер многострочного ввода
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $story)
                            .frame(minHeight: 100)
                        if story.isEmpty {
                            Text("Расскажите, что произошло…")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                }

                Section {
                    Button(action: { clearAll() }) {
                        Text("Очистить всё").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { hideKeyboard() }
                }
            }
            .navigationTitle("Формы")
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func clearAll() {
        name = ""; email = ""; password = ""; creditCard = ""; cvv = ""; story = ""
    }

    /// Форматирует ввод как "1234 5678 9012 3456".
    private func formatCard(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber).prefix(16)
        var chunks: [String] = []
        var i = digits.startIndex
        while i < digits.endIndex {
            let end = digits.index(i, offsetBy: 4, limitedBy: digits.endIndex) ?? digits.endIndex
            chunks.append(String(digits[i..<end]))
            i = end
        }
        return chunks.joined(separator: " ")
    }
}

// MARK: - Helper controls

private struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
        }
    }
}

private struct LabeledSecure: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            SecureField("••••••••", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

#Preview {
    FormsTab()
}
