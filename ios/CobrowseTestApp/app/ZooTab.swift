//
//  ZooTab.swift
//  CobrowseTestApp
//
//  «Зоопарк» разного контента для тестирования screen share на разнообразных
//  сценариях: длинный скролл, разные шрифты, картинки, sheet/alert-модалки,
//  типографика мелкого/крупного текста.
//

import SwiftUI

struct ZooTab: View {
    @State private var showSheet = false
    @State private var showAlert = false
    @State private var counter = 0

    var body: some View {
        NavigationView {
            List {
                Section("Типографика") {
                    Text("Крупный заголовок")
                        .font(.largeTitle.bold())
                    Text("Обычный body-текст — проверяет читаемость среднего размера через стрим.")
                        .font(.body)
                    Text("Мелкий текст 12pt — минимум для читабельности через 720p")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Моно шрифт с цифрами 0123456789")
                        .font(.system(.body, design: .monospaced))
                }

                Section("Цветовые блоки") {
                    HStack(spacing: 4) {
                        ForEach([Color.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink], id: \.self) { c in
                            Rectangle().fill(c).frame(height: 40)
                        }
                    }
                    .listRowInsets(EdgeInsets())

                    // Проверяет тонкие градиенты — часто первое, что деградирует в H264
                    LinearGradient(
                        colors: [.black, .white],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(height: 30)
                    .listRowInsets(EdgeInsets())
                }

                Section("Модалки") {
                    Button("Показать sheet") { showSheet = true }
                    Button("Показать alert") { showAlert = true }
                    NavigationLink("Перейти на другой экран") {
                        DetailView(counter: $counter)
                    }
                }

                // Sensitive-looking карточки — визуально имитируют то, что в реальном
                // приложении банка/страховой должно быть замаскировано.
                Section {
                    SensitiveCard(label: "Баланс", value: "1 234 567,89 ₽")
                    SensitiveCard(label: "Счёт", value: "40817 810 0 9876 5432100")
                    SensitiveCard(label: "СНИЛС", value: "123-456-789 01")
                } header: {
                    Label("Данные (мишень для redaction)", systemImage: "eye.slash")
                }

                Section("Длинный список") {
                    // Тест скролл-производительности и рендера повторяющихся ячеек
                    ForEach(0..<50) { i in
                        HStack {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color(hue: Double(i) / 50, saturation: 0.7, brightness: 0.9))
                            Text("Элемент №\(i + 1)")
                            Spacer()
                            Text("\(Int.random(in: 100...9999))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Всякое")
            .sheet(isPresented: $showSheet) {
                SheetContent(isPresented: $showSheet)
            }
            .alert("Тестовый alert", isPresented: $showAlert) {
                Button("ОК", role: .cancel) {}
                Button("Действие") {}
            } message: {
                Text("Проверяет, что модальные alert'ы корректно рендерятся в стриме.")
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Sensitive card

private struct SensitiveCard: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.monospaced())
        }
    }
}

// MARK: - Detail view (для навигации)

private struct DetailView: View {
    @Binding var counter: Int

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Второй экран")
                .font(.title.bold())

            Text("Переход между экранами полезен, чтобы проверить, как стрим переживает быструю смену UI и push/pop анимации.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Stepper("Счётчик: \(counter)", value: $counter)
                .padding()
        }
        .padding()
        .navigationTitle("Detail")
    }
}

// MARK: - Sheet content

private struct SheetContent: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Модальный экран")
                    .font(.title2.bold())
                Text("Sheet-презентация. Тест: видит ли web-agent слой поверх основного контента и корректно ли отрисовывается затемнение.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Spacer()
                Button("Закрыть") { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
            }
            .padding(.top, 40)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ZooTab()
}
