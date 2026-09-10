//
//  SupportChatView.swift
//  CobrowseTestApp
//
//  Экран «Чат с поддержкой». Один и тот же view открывается двумя путями:
//    • из плавающей кнопки (SupportFAB) — как fullScreenCover поверх текущего
//      экрана, чтобы «Назад» вернул ровно туда, где был пользователь;
//    • из настроек: Всякое → Настройки → Помощь и поддержка → Чат с поддержкой
//      (push внутри NavigationView вкладки).
//  В обоих случаях «Назад» — это @Environment(\.dismiss): pop при пуше и закрытие
//  презентации, когда view — корень NavigationStack в cover.
//
//  Данные — ChatStore из SDK (client.chat), отправка — client.sendChatMessage.
//

import SwiftUI

struct SupportChatView: View {
    @EnvironmentObject private var client: CobrowseClient

    var body: some View {
        SupportChatContent(chat: client.chat, canSend: canSend) { text in
            try client.sendChatMessage(text)
        }
    }

    /// Только .streaming: в .reconnecting транспорт не отправит (notConnected),
    /// в терминальных состояниях некому доставлять. Читать чат можно всегда.
    private var canSend: Bool {
        if case .streaming = client.state { return true }
        return false
    }
}

// MARK: - Контент

/// Отдельный view, чтобы наблюдать ChatStore напрямую: `client.chat` — вложенный
/// ObservableObject, его @Published не проходят через `client.objectWillChange`.
private struct SupportChatContent: View {
    @ObservedObject var chat: ChatStore
    let canSend: Bool
    let onSend: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var errorText: String?
    @FocusState private var inputFocused: Bool

    private let bottomAnchor = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            if chat.messages.isEmpty {
                ContentUnavailableView(
                    "Пока нет сообщений",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Напишите оператору или дождитесь его сообщения.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(chat.messages) { message in
                                MessageBubble(message: message)
                            }
                            Color.clear.frame(height: 1).id(bottomAnchor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    // Стартуем снизу; при появлении клавиатуры контент остаётся
                    // прижат к последнему сообщению без ручных хаков.
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chat.messages.count) { _, _ in
                        withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                    }
                }
            }

            Divider()
            inputBar
        }
        .navigationTitle("Чат с поддержкой")
        .navigationBarTitleDisplayMode(.inline)
        // Свой «Назад» вместо системного: в cover системной кнопки нет, а в
        // пуше она показывала бы заголовок предыдущего экрана. Цена — на этом
        // экране не работает swipe-back (приемлемо для PoC).
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    // Label в тулбаре рендерится только иконкой — поэтому HStack.
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Назад")
                    }
                }
                .accessibilityLabel("Назад")
            }
        }
        // isOpen: входящие не копят unread, FAB прячется. onAppear/onDisappear
        // срабатывают и при переключении табов с запушенным экраном — это
        // корректно: на другом табе FAB снова виден.
        .onAppear { chat.isOpen = true }
        .onDisappear { chat.isOpen = false }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if !canSend {
                Text("Чат доступен во время сессии с оператором")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                // Однострочное поле: с axis: .vertical Return вставляет перенос,
                // а не отправляет.
                TextField("Сообщение…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .disabled(!canSend)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Отправить")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        do {
            try onSend(draft)
            draft = ""
            errorText = nil
            inputFocused = true   // чат-стиль: клавиатура остаётся для следующего сообщения
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Пузырь сообщения

/// Своё — справа, синее; оператор — слева, серое, с подписью identity.
private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 48) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                if !message.isMine {
                    Text(message.author)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.isMine ? Color.accentColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .foregroundStyle(message.isMine ? Color.white : Color.primary)
                Text(Date(timeIntervalSince1970: message.ts / 1000), style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !message.isMine { Spacer(minLength: 48) }
        }
    }
}

#Preview {
    NavigationStack {
        SupportChatView()
            .environmentObject(CobrowseClient(backendURL: AppConfig.backendURL))
    }
}
