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

import Foundation
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
    private var targetFps: Int = 15
    private var minFrameIntervalNs: Int64 = 66_666_666  // ~15 fps default

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

        // Ждём первый обработанный кадр или таймаут.
        // RPScreenRecorder выдаёт кадры не сразу — обычно 100-300ms.
        // Таймаут — защита от зависания если что-то пошло не так с capture handler'ом.
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
    }

    public func stop() async {
        // Разрезолвить залипший continuation, чтобы предыдущий start() не висел
        // (или не крашил Swift 6 runtime — leaked continuation is a bug).
        if let cont = firstFrameContinuation {
            firstFrameContinuation = nil
            cont.resume()
        }
        if recorder.isRecording {
            try? await recorder.stopCapture()
        }
        // Пул и format description освобождаются автоматически при следующем start.
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
