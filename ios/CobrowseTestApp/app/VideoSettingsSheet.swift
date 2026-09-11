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

    /// Последнее явное значение битрейта — чтобы при выключении «без
    /// ограничения» слайдер вернулся туда, где был, а не на константу.
    @State private var lastLimitedKbps: Int

    init(current: ScreenShareOptions) {
        _draft = State(initialValue: current)
        _lastLimitedKbps = State(initialValue: current.maxBitrateKbps ?? 1500)
    }

    /// Ресолюционные пресеты — фиксированный набор из VideoDimensions.
    /// Держим отдельно, чтобы Picker знал перечислимый список.
    /// Мелкие разрешения (240p/360p) нужны для low-bitrate экспериментов —
    /// на 100 kbps 720p превращается в кашу, а 240p ещё читаемый.
    private let resolutions: [(label: String, value: VideoDimensions)] = [
        ("240p (426×240)",    .h240_169),
        ("360p (640×360)",    .h360_169),
        ("480p (854×480)",    .h480_169),
        ("720p (1280×720)",   .h720_169),
        ("1080p (1920×1080)", .h1080_169),
    ]

    /// FPS-пресеты для screen-share. Дефолт для демо по Wi-Fi — 60: гладкие
    /// скролл и анимации. 15 хватает для статичного UI, ниже 5 — уже слайдшоу.
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
                    // Дефолт для демо по Wi-Fi: без ограничения — encoder получает
                    // высокий потолок, реальную скорость выбирает BWE
                    // (ScreenShareOptions.unlimitedBitrateCapKbps).
                    Toggle("Без ограничения", isOn: unlimitedBinding)
                    if let kbps = draft.maxBitrateKbps {
                        // Slider [50, 5000] kbps, шаг 50: низ — для low-bitrate
                        // экспериментов (100 kbps → 240p), верх — HD/FHD.
                        Slider(
                            value: bitrateBinding,
                            in: 50...5000,
                            step: 50
                        )
                        Text("\(kbps) kbps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Максимальный битрейт")
                } footer: {
                    if draft.maxBitrateKbps == nil {
                        Text("Потолок \(ScreenShareOptions.unlimitedBitrateCapKbps / 1000) Мбит/с, фактическую скорость LiveKit выбирает по оценке канала. Для демо по Wi-Fi — лучшая картинка.")
                    } else {
                        Text("Верхняя граница. LiveKit адаптивно снижает при узкой сети. Для low-bitrate тестов подбирай разрешение под битрейт: 100 kbps → 240p.")
                    }
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

    /// Тумблер «без ограничения» ↔ nil в maxBitrateKbps. При выключении
    /// возвращаем последнее явное значение.
    private var unlimitedBinding: Binding<Bool> {
        Binding(
            get: { draft.maxBitrateKbps == nil },
            set: { unlimited in
                if unlimited {
                    if let kbps = draft.maxBitrateKbps { lastLimitedKbps = kbps }
                    draft.maxBitrateKbps = nil
                } else {
                    draft.maxBitrateKbps = lastLimitedKbps
                }
            }
        )
    }

    /// Slider работает с Double, наш kbps — Int?. Показывается только когда
    /// лимит задан, поэтому nil здесь — лишь страховка.
    private var bitrateBinding: Binding<Double> {
        Binding(
            get: { Double(draft.maxBitrateKbps ?? lastLimitedKbps) },
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
