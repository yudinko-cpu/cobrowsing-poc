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
        screenTrack = nil
        audioTrack = nil
        connectionState = .disconnected
    }

    public func publishScreenShare(options: ScreenShareOptions) async throws {
        guard connectionState == .connected else { throw TransportError.notConnected }
        guard screenTrack == nil else { throw TransportError.alreadyPublishing }

        let dims = Dimensions(
            width: Int32(options.dimensions.width),
            height: Int32(options.dimensions.height)
        )
        let track = LocalVideoTrack.createInAppScreenShareTrack(
            options: ScreenShareCaptureOptions(
                dimensions: dims,
                fps: options.fps,
                useBroadcastExtension: options.useBroadcastExtension
            )
        )
        do {
            try await room.localParticipant.publish(videoTrack: track)
            screenTrack = track
        } catch {
            throw TransportError.publishFailed(error.localizedDescription)
        }
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
