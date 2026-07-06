//
//  LiveKitTransport.swift
//  CobrowsePOC
//
//  Реализация CobrowseTransport поверх LiveKit Swift SDK.
//  Единственное место в SDK, где импортируется `import LiveKit`.
//
//  При смене транспорта (raw libwebrtc, mediasoup, whatever) —
//  этот файл заменяется параллельной реализацией, всё остальное не трогается.
//

import Foundation
import LiveKit

public final class LiveKitTransport: CobrowseTransport {

    // MARK: - Public

    public weak var delegate: CobrowseTransportDelegate?

    public private(set) var connectionState: ConnectionState = .disconnected {
        didSet {
            guard oldValue != connectionState else { return }
            delegate?.transport(self, didChangeConnectionState: connectionState)
        }
    }

    // MARK: - Private

    private let room: Room
    private var screenTrack: LocalVideoTrack?
    private var audioTrack: LocalAudioTrack?

    /// Наш custom capturer вместо штатного InAppScreenCapturer.
    /// Держим ссылку, чтобы (а) не был gc'ен пока трек живёт, (б) остановить
    /// при unpublish/republish/disconnect.
    private var screenCapturer: ScaledScreenShareCapturer?

    /// LiveKit требует RoomDelegate — держим его отдельным объектом, чтобы не
    /// торчать LiveKit-протоколом наружу через LiveKitTransport.
    private var roomDelegateProxy: RoomDelegateProxy!

    public init() {
        self.room = Room()
        self.roomDelegateProxy = RoomDelegateProxy(owner: self)
        self.room.add(delegate: self.roomDelegateProxy)
    }

    // MARK: - CobrowseTransport

    public func connect(url: String, token: String) async throws {
        guard connectionState == .disconnected else {
            throw TransportError.connectFailed("уже подключено или подключается")
        }
        connectionState = .connecting
        do {
            try await room.connect(
                url: url,
                token: token,
                connectOptions: ConnectOptions(autoSubscribe: true)
            )
            connectionState = .connected
        } catch {
            connectionState = .disconnected
            throw TransportError.connectFailed(error.localizedDescription)
        }
    }

    public func disconnect() async {
        await room.disconnect()
        await screenCapturer?.stop()
        screenCapturer = nil
        screenTrack = nil
        audioTrack = nil
        connectionState = .disconnected
    }

    public func publishScreenShare(options: ScreenShareOptions) async throws {
        guard connectionState == .connected else { throw TransportError.notConnected }
        guard screenTrack == nil else { throw TransportError.alreadyPublishing }

        // Buffer track — вручную кормим capturer'а из ScaledScreenShareCapturer,
        // который между RPScreenRecorder и BufferCapturer вставляет CIImage-даунскейл.
        // Штатный createInAppScreenShareTrack игнорирует dimensions и отдаёт
        // нативное разрешение iPhone (см. заметки в ScaledScreenShareCapturer.swift).
        let track = LocalVideoTrack.createBufferTrack(
            name: Track.screenShareVideoName,
            source: .screenShareVideo
        )
        guard let bufferCapturer = track.capturer as? BufferCapturer else {
            throw TransportError.publishFailed("track.capturer не BufferCapturer — SDK изменил API?")
        }

        let downscaler = ScaledScreenShareCapturer()
        downscaler.onSampleBuffer = { sample in
            bufferCapturer.capture(sample)
        }

        let shortSide = min(options.dimensions.width, options.dimensions.height)
        do {
            // start() возвращается ТОЛЬКО после первого эмитнутого кадра, иначе
            // publish упадёт с "publish timeout" (dimensions ещё не резолвились).
            try await downscaler.start(targetShortSide: shortSide, targetFps: options.fps)
        } catch {
            throw TransportError.publishFailed("screen capture start: \(error.localizedDescription)")
        }

        do {
            try await room.localParticipant.publish(
                videoTrack: track,
                options: buildVideoPublishOptions(from: options)
            )
            screenTrack = track
            screenCapturer = downscaler
        } catch {
            await downscaler.stop()
            throw TransportError.publishFailed(error.localizedDescription)
        }
    }

    public func republishScreenShare(options: ScreenShareOptions) async throws {
        guard connectionState == .connected else { throw TransportError.notConnected }

        // Снимаем текущую публикацию и останавливаем capturer — новые dims/fps
        // требуют пересоздания CVPixelBufferPool + track с новой BufferCapturer'ой.
        if let s = screenTrack {
            if let pub = room.localParticipant.localVideoTracks.first(where: { $0.track === s }) {
                try? await room.localParticipant.unpublish(publication: pub)
            }
            screenTrack = nil
        }
        await screenCapturer?.stop()
        screenCapturer = nil

        try await publishScreenShare(options: options)
    }

    /// Маппинг нейтральных ScreenShareOptions → LiveKit VideoPublishOptions.
    ///
    /// preferredCodec — best-effort, финальный кодек определяет SFU
    /// на основе enabled_codecs в livekit.yaml.
    ///
    /// simulcast: false — разрешение уже зафиксировано на входе
    /// (ScaledScreenShareCapturer даунскейлит CVPixelBuffer до целевого).
    /// Simulcast с single-layer и layers-пресеты SDK не помогли обуздать
    /// screen share dimensions — теперь мы сами сжимаем перед encoder'ом.
    private func buildVideoPublishOptions(from options: ScreenShareOptions) -> VideoPublishOptions {
        let liveKitCodec: LiveKit.VideoCodec = switch options.codec {
        case .h264: .h264
        case .vp8:  .vp8
        case .vp9:  .vp9
        case .av1:  .av1
        }
        let encoding = VideoEncoding(
            maxBitrate: (options.maxBitrateKbps ?? 500) * 1000,
            maxFps: options.fps
        )
        return VideoPublishOptions(
            name: Track.screenShareVideoName,
            screenShareEncoding: encoding,
            simulcast: false,
            preferredCodec: liveKitCodec
        )
    }

    public func publishAudio(options: AudioOptions) async throws {
        guard connectionState == .connected else { throw TransportError.notConnected }
        guard audioTrack == nil else { throw TransportError.alreadyPublishing }

        let track = LocalAudioTrack.createTrack(options: AudioCaptureOptions(
            echoCancellation: options.echoCancellation,
            noiseSuppression: options.noiseSuppression
        ))
        do {
            try await room.localParticipant.publish(audioTrack: track)
            audioTrack = track
        } catch {
            throw TransportError.publishFailed(error.localizedDescription)
        }
    }

    public func unpublishAll() async {
        if let s = screenTrack {
            if let pub = room.localParticipant.localVideoTracks.first(where: { $0.track === s }) {
                try? await room.localParticipant.unpublish(publication: pub)
            }
            screenTrack = nil
        }
        await screenCapturer?.stop()
        screenCapturer = nil
        if let a = audioTrack {
            if let pub = room.localParticipant.localAudioTracks.first(where: { $0.track === a }) {
                try? await room.localParticipant.unpublish(publication: pub)
            }
            audioTrack = nil
        }
    }

    public func sendData(_ data: Data, topic: String, reliable: Bool) async throws {
        guard connectionState == .connected else { throw TransportError.notConnected }
        do {
            try await room.localParticipant.publish(
                data: data,
                options: DataPublishOptions(topic: topic, reliable: reliable)
            )
        } catch {
            throw TransportError.publishFailed(error.localizedDescription)
        }
    }

    // MARK: - Внутренние хендлеры LiveKit-событий (мостим в нейтральный delegate)

    fileprivate func handleRoomDidDisconnect(with error: Error?) {
        // Здесь можно расширить маппинг LiveKitError → TransportDisconnectReason.
        // Пока — простое разделение штатное / сетевое.
        let reason: TransportDisconnectReason = (error == nil) ? .userInitiated : .networkError
        connectionState = .disconnected
        delegate?.transport(self, didDisconnectWithReason: reason)
    }

    fileprivate func handleRoomIsReconnecting() {
        connectionState = .reconnecting
    }

    fileprivate func handleRoomDidReconnect() {
        connectionState = .connected
    }

    fileprivate func handleDataReceived(_ data: Data, topic: String?, from identity: String?) {
        delegate?.transport(
            self,
            didReceiveData: data,
            topic: topic ?? "",
            fromParticipantIdentity: identity
        )
    }
}

// MARK: - LiveKit RoomDelegate proxy

/// Единственный класс, который реализует LiveKit.RoomDelegate.
/// Держим отдельным, чтобы LiveKitTransport не exposed соответствующий протокол наружу.
private final class RoomDelegateProxy: NSObject, LiveKit.RoomDelegate {

    nonisolated(unsafe) weak var owner: LiveKitTransport?

    init(owner: LiveKitTransport) {
        self.owner = owner
        super.init()
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        owner?.handleRoomDidDisconnect(with: error)
    }

    func roomIsReconnecting(_ room: Room) {
        owner?.handleRoomIsReconnecting()
    }

    func roomDidReconnect(_ room: Room) {
        owner?.handleRoomDidReconnect()
    }

    func room(_ room: Room,
              participant: RemoteParticipant?,
              didReceiveData data: Data,
              forTopic topic: String,
              encryptionType: EncryptionType) {
        owner?.handleDataReceived(
            data,
            topic: topic,
            from: participant?.identity?.stringValue
        )
    }
}
