//
//  ScaledScreenShareCapturer.swift
//  CobrowsePOC
//
//  Кастомный screen-share capturer, который решает проблему LiveKit iOS SDK:
//  штатный `createInAppScreenShareTrack` НЕ даунскейлит CVPixelBuffer от
//  RPScreenRecorder, отдаёт нативное разрешение iPhone (886×1920 портрет).
//  `screenShareSimulcastLayers` тоже не работает надёжно — SFU/encoder
//  игнорируют scaleResolutionDownBy для screen share пресетов.
//
//  Мы вставляем свой шаг между RPScreenRecorder и BufferCapturer:
//    RPScreenRecorder → CIImage.transform(scale) → CVPixelBuffer из пула
//    → CMSampleBuffer → BufferCapturer.capture()
//
//  Плюс FPS-троттлинг (RPScreenRecorder делает 30-60fps независимо от того,
//  что мы просим — режем по времени последнего отправленного кадра).
//
//  GPU-render через CIContext (Metal). CPU-нагрузка от даунскейла < 5%
//  на iPhone 13+ при 720p → 240p.
//
//  Фон. ReplayKit прекращает in-app захват, когда приложение уходит в фон, и
//  сам его не возобновляет; LiveKit при этом приостанавливает/возобновляет
//  только camera-треки, screen-share не трогает. Без вмешательства трек
//  остаётся опубликованным, но кадры не идут — оператор видит замёрзший экран
//  до ближайшего republish. Поэтому capturer сам следит за didEnterBackground /
//  didBecomeActive и перезапускает recorder на том же треке.
//

import Foundation
import UIKit
import ReplayKit
import CoreImage
import CoreVideo
import CoreMedia

/// Захватывает экран через ReplayKit, даунскейлит CVPixelBuffer по aspect-preserve
/// принципу (короткая сторона = targetShortSide), троттлит по fps, эмитит
/// готовые CMSampleBuffer через `onSampleBuffer`.
///
/// Не thread-safe — вызывать start/stop только с main actor.
/// Хендлер RPScreenRecorder приходит на background thread; downscale и эмит
/// делаются там же, потребитель (BufferCapturer) сам разбирается с очередью.
public final class ScaledScreenShareCapturer {

    // MARK: - Configuration

    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: - Private state

    private let recorder = RPScreenRecorder.shared()
    private let ciContext: CIContext

    private var targetShortSide: Int = 720
    private var targetFps: Int = 60
    private var minFrameIntervalNs: Int64 = 16_666_666  // ~60 fps, как дефолт ScreenShareOptions

    private var outputPool: CVPixelBufferPool?
    private var outputWidth: Int = 0
    private var outputHeight: Int = 0
    private var outputFormatDescription: CMFormatDescription?

    private var lastEmittedPtsNs: Int64 = -1

    /// Разово резолвится по первому кадру — нужен для `waitForFirstFrame()`,
    /// потому что LiveKit publish требует, чтобы capturer уже эмитнул кадр
    /// (иначе dimensions не выведены, publish таймаутит на 10с).
    private var firstFrameContinuation: CheckedContinuation<Void, Never>?
    private var didEmitFirstFrame = false

    /// Между успешным start() и stop(): захват должен идти. По этому флагу
    /// решаем, восстанавливать ли его после возврата из фона.
    private var isStarted = false
    /// Приложение уходило в фон после старта захвата — ReplayKit его прекратил.
    /// Именно didEnterBackground, а не willResignActive: системный алерт
    /// (в том числе запрос ReplayKit на запись экрана) тоже снимает active,
    /// но захват не рвёт — перезапуск там был бы лишним и опасным.
    private var interruptedByBackground = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: - Init

    public init() {
        // Metal-контекст: реальный GPU-render, работает быстрее CPU CIContext.
        // На симуляторе fall back на software (CI сам разберётся).
        let device = MTLCreateSystemDefaultDevice()
        self.ciContext = device.map { CIContext(mtlDevice: $0) } ?? CIContext()
    }

    // MARK: - Public API

    /// Запустить захват. `targetShortSide` — короткая сторона выходного кадра
    /// (aspect сохраняется, длинная сторона пропорционально масштабируется).
    /// После возврата — как минимум один кадр уже отправлен в `onSampleBuffer`,
    /// т.е. можно безопасно вызывать LiveKit publish.
    public func start(targetShortSide: Int, targetFps: Int) async throws {
        self.targetShortSide = max(120, targetShortSide)
        self.targetFps = max(1, targetFps)
        self.minFrameIntervalNs = Int64(1_000_000_000 / self.targetFps)

        self.lastEmittedPtsNs = -1
        self.outputPool = nil
        self.outputWidth = 0
        self.outputHeight = 0
        self.outputFormatDescription = nil
        self.didEmitFirstFrame = false

        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false

        // Если предыдущий сеанс ещё "закрывается" (isRecording=true после stop
        // на короткое время) — startCapture может отказать. Ждём чуть-чуть.
        var attempt = 0
        while recorder.isRecording && attempt < 20 {  // до 1 секунды
            try? await Task.sleep(nanoseconds: 50_000_000)
            attempt += 1
        }

        try await startRecorder()

        // Ждём первый обработанный кадр или таймаут.
        // RPScreenRecorder выдаёт кадры не сразу — обычно 100-300ms.
        // Таймаут — защита от зависания если что-то пошло не так с capture handler'ом.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if self.didEmitFirstFrame {
                            cont.resume()
                        } else {
                            self.firstFrameContinuation = cont
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)  // 5с таймаут
                    throw CapturerError.firstFrameTimeout
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            // Recorder уже запущен — не оставляем его крутиться без хозяина,
            // иначе следующий start() упрётся в isRecording.
            firstFrameContinuation = nil
            if recorder.isRecording {
                recorder.stopCapture()   // sync-перегрузка с nil completion; ждём isRecording ниже / при следующем старте
            }
            throw error
        }

        isStarted = true
        interruptedByBackground = false
        installLifecycleObservers()
    }

    public func stop() async {
        isStarted = false
        interruptedByBackground = false
        removeLifecycleObservers()
        // Разрезолвить залипший continuation, чтобы предыдущий start() не висел
        // (или не крашил Swift 6 runtime — leaked continuation is a bug).
        if let cont = firstFrameContinuation {
            firstFrameContinuation = nil
            cont.resume()
        }
        if recorder.isRecording {
            recorder.stopCapture()   // sync-перегрузка с nil completion; ждём isRecording ниже / при следующем старте
        }
        // Пул и format description освобождаются автоматически при следующем start.
    }

    // MARK: - Recorder

    /// Собственно RPScreenRecorder.startCapture с нашим хендлером. Общий для
    /// первого старта и перезапуска после фона.
    private func startRecorder() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            recorder.startCapture(
                handler: { [weak self] sampleBuffer, bufferType, error in
                    guard error == nil else { return }
                    guard bufferType == .video else { return }
                    self?.handle(sampleBuffer: sampleBuffer)
                },
                completionHandler: { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    // MARK: - Фон / возврат

    private func installLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.noteBackground() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.resumeAfterBackground() }
        })
    }

    private func removeLifecycleObservers() {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    private func noteBackground() {
        guard isStarted else { return }
        interruptedByBackground = true
    }

    /// Возврат из фона: ReplayKit захват уже мёртв (или встанет при первом же
    /// кадре), перезапускаем его на том же треке. didBecomeActive, а не
    /// willEnterForeground: startCapture требует активного приложения.
    private func resumeAfterBackground() async {
        guard isStarted, interruptedByBackground else { return }
        interruptedByBackground = false
        await restartCapture()
    }

    private func restartCapture() async {
        if recorder.isRecording {
            recorder.stopCapture()   // sync-перегрузка с nil completion; ждём isRecording ниже / при следующем старте
        }
        // Как в start(): после stop recorder ещё чуть-чуть «закрывается».
        var attempt = 0
        while recorder.isRecording && attempt < 20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            attempt += 1
        }
        // Троттлинг и размеры выхода выводим заново по первому кадру: в фоне
        // могли повернуть устройство, а PTS после паузы не обязан продолжать ряд.
        lastEmittedPtsNs = -1
        outputPool = nil
        outputFormatDescription = nil
        do {
            try await startRecorder()
        } catch {
            // Не роняем сессию: оператор увидит замёрзший кадр, как и раньше,
            // а смена настроек видео (republish) по-прежнему всё поднимет.
            #if DEBUG
            print("[ScaledScreenShareCapturer] restart after background failed: \(error)")
            #endif
        }
    }

    public enum CapturerError: LocalizedError {
        case firstFrameTimeout
        public var errorDescription: String? {
            switch self {
            case .firstFrameTimeout:
                return "ReplayKit не отдал первый кадр за 5с — возможно нет consent'а или recorder в неконсистентном состоянии"
            }
        }
    }

    // MARK: - Frame processing

    private func handle(sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNs = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)

        // FPS-троттлинг по PTS от источника (не по wallclock — так корректнее
        // отсекать кадры при батчинге RPScreenRecorder).
        if lastEmittedPtsNs >= 0, (ptsNs - lastEmittedPtsNs) < minFrameIntervalNs {
            return
        }

        guard let src = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        guard srcW > 0, srcH > 0 else { return }

        // Lazy init пула и format description — размер выхода известен после
        // первого кадра (RPScreenRecorder может отдавать разные dims при поворотах,
        // но в нашем PoC screen-share жёстко портретный).
        if outputPool == nil {
            let srcShortSide = min(srcW, srcH)
            let scale = Double(targetShortSide) / Double(srcShortSide)
            // Encoder'ы хотят чётные dims, режем в меньшую сторону.
            let outW = max(2, (Int(Double(srcW) * scale) / 2) * 2)
            let outH = max(2, (Int(Double(srcH) * scale) / 2) * 2)
            outputWidth = outW
            outputHeight = outH
            outputPool = makePool(width: outW, height: outH)
        }

        guard let pool = outputPool else { return }
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
        guard let dstBuf = dst else { return }

        // Даунскейл. Aspect сохраняется — source и output share один scale.
        let srcImage = CIImage(cvPixelBuffer: src)
        let scaleX = CGFloat(outputWidth) / CGFloat(srcW)
        let scaleY = CGFloat(outputHeight) / CGFloat(srcH)
        let scaled = srcImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaled, to: dstBuf)

        // Оборачиваем CVPixelBuffer в CMSampleBuffer с PTS источника.
        guard let sample = makeSampleBuffer(pixelBuffer: dstBuf, pts: pts) else { return }

        lastEmittedPtsNs = ptsNs
        onSampleBuffer?(sample)

        if !didEmitFirstFrame {
            didEmitFirstFrame = true
            firstFrameContinuation?.resume()
            firstFrameContinuation = nil
        }
    }

    // MARK: - Helpers

    private func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let pixelAttrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, pixelAttrs as CFDictionary, &pool)
        return pool
    }

    /// Создать CMSampleBuffer из CVPixelBuffer + timing.
    /// format description кэшируем — она стабильна пока не меняются dims/format.
    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        if outputFormatDescription == nil {
            var fd: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &fd
            )
            guard status == noErr, let fd else { return nil }
            outputFormatDescription = fd
        }
        guard let formatDesc = outputFormatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuf: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuf
        )
        guard status == noErr else { return nil }
        return sampleBuf
    }
}
