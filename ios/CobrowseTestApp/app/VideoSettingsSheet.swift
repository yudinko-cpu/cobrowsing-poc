//
//  VideoSettingsSheet.swift
//  CobrowseTestApp
//
//  Sheet с live-настройками screen-share для активной сессии.
//  Показывается из SessionTab по кнопке-шестерёнке в NavigationBar.
//
//  UX: пользователь крутит слайдер/пикеры → жмёт "Применить" → CobrowseClient
//  делает republishScreenShare через LiveKit. Оператор видит короткий blip
//  (≈ 0.5–1с), сессия не рвётся.
//

import SwiftUI

struct VideoSettingsSheet: View {

    @EnvironmentObject var client: CobrowseClient
    @Environment(\.dismiss) private var dismiss

    /// Черновик настроек. Не применяется до кнопки Apply — так пользователь
    /// не роняет качество сессии, случайно двинув слайдер.
    @State private var draft: ScreenShareOptions

    @State private var applying = false
    @State private var errorMessage: String?

    init(current: ScreenShareOptions) {
        _draft = State(initialValue: current)
    }

    /// Ресолюционные пресеты — фиксированный набор из VideoDimensions.
    /// Держим отдельно, чтобы Picker знал перечислимый список.
    private let resolutions: [(label: String, value: VideoDimensions)] = [
        ("480p (854×480)",   .h480_169),
        ("720p (1280×720)",  .h720_169),
        ("1080p (1920×1080)", .h1080_169),
    ]

    /// FPS-пресеты для screen-share. Живой скролл/анимации ок с 15,
    /// 30 нужен только для сильно-динамичного контента (игры, видео).
    /// Ниже 5 — уже слайдшоу, не имеет смысла.
    private let fpsOptions: [Int] = [5, 10, 15, 20, 30, 45, 60]

    /// Кнопка Apply актуальна, только если черновик реально отличается
    /// от того, что сейчас применено. Убирает случайные re-publish'и.
    private var hasChanges: Bool {
        draft != client.screenShareOptions
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Кодек") {
                    Picker("Кодек", selection: $draft.codec) {
                        ForEach(VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Разрешение") {
                    Picker("Разрешение", selection: dimensionsBinding) {
                        ForEach(resolutions, id: \.value.width) { res in
                            Text(res.label).tag(res.value)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Picker("FPS", selection: $draft.fps) {
                        ForEach(fpsOptions, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Максимальный FPS")
                } footer: {
                    Text("Ограничивает и ReplayKit-capture, и encoder. Выше = плавнее, но дороже по трафику и батарее.")
                }

                Section {
                    // Slider на [500, 5000] kbps, шаг 250 — удобно двигать пальцем.
                    Slider(
                        value: bitrateBinding,
                        in: 500...5000,
                        step: 250
                    )
                    Text("\(draft.maxBitrateKbps ?? 1500) kbps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Максимальный битрейт")
                } footer: {
                    Text("Верхняя граница. LiveKit адаптивно снижает при узкой сети.")
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Настройки видео")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(applying ? "Применяется…" : "Применить") {
                        Task { await apply() }
                    }
                    .disabled(!hasChanges || applying)
                }
            }
            .disabled(applying)
        }
    }

    // MARK: - Bindings

    /// VideoDimensions — struct без Hashable, поэтому Picker селект удобнее
    /// делать через custom binding с ручным сравнением width.
    private var dimensionsBinding: Binding<VideoDimensions> {
        Binding(
            get: { draft.dimensions },
            set: { draft.dimensions = $0 }
        )
    }

    /// Slider работает с Double, наш kbps — Int?. Мостим через Double,
    /// nil в UI не поддерживаем — если пользователь ушёл со слайдера,
    /// значит хочет явное значение.
    private var bitrateBinding: Binding<Double> {
        Binding(
            get: { Double(draft.maxBitrateKbps ?? 1500) },
            set: { draft.maxBitrateKbps = Int($0) }
        )
    }

    // MARK: - Actions

    private func apply() async {
        applying = true
        errorMessage = nil
        defer { applying = false }
        do {
            try await client.updateScreenShareOptions(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    VideoSettingsSheet(current: ScreenShareOptions())
        .environmentObject(CobrowseClient(backendURL: AppConfig.backendURL))
}
