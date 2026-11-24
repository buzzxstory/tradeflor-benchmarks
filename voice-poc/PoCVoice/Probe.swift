import CryptoKit
import Foundation
import LiveKit
import MachO
import ObjectiveC
import WebRTC

/// Exercises stasel WebRTC (RTC*) and LiveKit (LiveKitWebRTC, LKRTC*) in one process.
public enum Probe {
    // kept alive for the life of the process
    static var staselFactory: RTCPeerConnectionFactory?
    static var staselPC: RTCPeerConnection?
    static var lkRoom: Room?
    static var lkTrack: LocalAudioTrack?

    @discardableResult
    public static func initStasel() -> Bool {
        if staselPC != nil { return true }
        RTCInitializeSSL()
        let f = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                         decoderFactory: RTCDefaultVideoDecoderFactory())
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        let pc = f.peerConnection(with: cfg,
                                  constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                                  delegate: nil)
        let source = f.audioSource(with: nil)
        let track = f.audioTrack(with: source, trackId: "a0")
        _ = pc?.add(track, streamIds: ["s0"])
        staselFactory = f
        staselPC = pc
        return pc != nil
    }

    /// LiveKit room + a microphone-only local audio track (no camera). Does not connect.
    public static func initLiveKit() async -> (room: String, track: String) {
        let room = Room(roomOptions: RoomOptions(defaultAudioCaptureOptions: AudioCaptureOptions(),
                                                 adaptiveStream: false, dynacast: false))
        let track = await LocalAudioTrack.createTrack(name: "microphone", options: AudioCaptureOptions())
        lkRoom = room
        lkTrack = track
        return ("\(room.connectionState)", "\(track.name) source=\(track.source)")
    }

    public static func loadedImage(containing fragment: String) -> String? {
        for i in 0 ..< _dyld_image_count() {
            if let c = _dyld_get_image_name(i) {
                let s = String(cString: c)
                if s.contains(fragment) { return s }
            }
        }
        return nil
    }

    public static func allLoadedImages() -> [String] {
        (0 ..< _dyld_image_count()).compactMap { i in _dyld_get_image_name(i).map { String(cString: $0) } }
    }

    public static func classNames(inImage path: String) -> [String] {
        var count: UInt32 = 0
        guard let names = objc_copyClassNamesForImage(path, &count) else { return [] }
        defer { free(UnsafeMutableRawPointer(mutating: names)) }
        return (0 ..< Int(count)).map { String(cString: names[$0]) }
    }

    /// Every ObjC class name registered more than once across all loaded images (any framework pair).
    public static func duplicateClassNamesProcessWide() -> [String: [String]] {
        var byName = [String: [String]]()
        for img in allLoadedImages() {
            for n in classNames(inImage: img) { byName[n, default: []].append(img) }
        }
        return byName.filter { $0.value.count > 1 }
    }

    // MARK: checks called by the unit tests

    public static func checkBothInitialise() async -> [(String, String)] {
        let ok = initStasel()
        let lk = await initLiveKit()
        return [("a.stasel_peer_connection", ok ? "created" : "nil"),
                ("a.livekit_room_state", lk.room),
                ("a.livekit_local_audio_track", lk.track)]
    }

    public static func checkDuplicateClasses() async -> ([(String, String)], Int) {
        _ = initStasel()
        _ = await initLiveKit()
        var rows = [(String, String)]()
        let stasel = loadedImage(containing: "/WebRTC.framework/WebRTC")
        let lkweb = loadedImage(containing: "/LiveKitWebRTC.framework/LiveKitWebRTC")
        rows.append(("b.stasel_image_loaded", stasel.map { ($0 as NSString).lastPathComponent } ?? "NOT LOADED"))
        rows.append(("b.livekitwebrtc_image_loaded", lkweb.map { ($0 as NSString).lastPathComponent } ?? "NOT LOADED"))
        let fw = allLoadedImages().filter { $0.contains(".app/") }
            .map { ($0 as NSString).lastPathComponent }.sorted()
        rows.append(("b.images_loaded_from_app_bundle", fw.joined(separator: ",")))
        guard let s = stasel, let l = lkweb else { return (rows, -1) }
        let a = Set(classNames(inImage: s))
        let b = Set(classNames(inImage: l))
        let overlap = a.intersection(b).sorted()
        rows.append(("b.stasel_objc_classes", "\(a.count)"))
        rows.append(("b.livekitwebrtc_objc_classes", "\(b.count)"))
        rows.append(("b.stasel_sample", a.sorted().prefix(4).joined(separator: ",")))
        rows.append(("b.livekitwebrtc_sample", b.sorted().prefix(4).joined(separator: ",")))
        rows.append(("b.stasel_classes_without_RTC_prefix", "\(a.filter { !$0.hasPrefix("RTC") }.count)"))
        rows.append(("b.livekitwebrtc_classes_without_LKRTC_prefix", "\(b.filter { !$0.hasPrefix("LKRTC") }.count)"))
        rows.append(("b.duplicate_class_names_between_the_two", "\(overlap.count)"))
        if !overlap.isEmpty { rows.append(("b.duplicates_list", overlap.prefix(50).joined(separator: ","))) }
        let wide = duplicateClassNamesProcessWide().filter { $0.value.contains { $0.contains(".app/") } }
        rows.append(("b.processwide_duplicates_involving_app_bundle", "\(wide.count)"))
        if !wide.isEmpty { rows.append(("b.processwide_duplicates_list", wide.keys.sorted().prefix(50).joined(separator: ","))) }
        return (rows, overlap.count)
    }

    public static func connectAndPublish(url: String) async -> ([(String, String)], Bool) {
        var rows = [(String, String)]()
        let token = devToken(identity: "ios-sim", room: "ios-poc", sources: ["microphone"])
        let room = Room()
        let t0 = Date()
        do {
            try await room.connect(url: url, token: token)
            rows.append(("d.connect", "\(room.connectionState) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s"))
        } catch {
            rows.append(("d.connect", "FAILED \(error)"))
            return (rows, false)
        }
        let connected = room.connectionState == .connected
        let track = await LocalAudioTrack.createTrack(name: "microphone", options: AudioCaptureOptions())
        do {
            let desc = try await withTimeout(20) {
                let pub = try await room.localParticipant.publish(audioTrack: track)
                return "ACCEPTED sid=\(pub.sid) source=\(pub.source)"
            }
            rows.append(("d.publish_microphone", desc))
        } catch {
            rows.append(("d.publish_microphone", "NOT PUBLISHED: \(error)"))
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        rows.append(("d.audio_engine_running", "\(AudioManager.shared.isEngineRunning)"))
        rows.append(("d.input_devices", AudioManager.shared.inputDevices.map(\.name).joined(separator: ",")))
        await room.disconnect()
        return (rows, connected)
    }

    static func withTimeout(_ seconds: Double, _ op: @escaping @Sendable () async throws -> String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { g in
            g.addTask { try await op() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "PoC", code: 1, userInfo: [NSLocalizedDescriptionKey: "timeout after \(seconds)s"])
            }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }

    public static func audioSessionControls() -> [(String, String)] {
        var rows = [(String, String)]()
        let am = AudioManager.shared
        rows.append(("e.livekit_audioSession.isAutomaticConfigurationEnabled_default", "\(am.audioSession.isAutomaticConfigurationEnabled)"))
        am.audioSession.isAutomaticConfigurationEnabled = false
        rows.append(("e.livekit_isAutomaticConfigurationEnabled_settable_to_false", "\(!am.audioSession.isAutomaticConfigurationEnabled)"))
        am.audioSession.isAutomaticConfigurationEnabled = true
        rows.append(("e.livekit_engineAvailability_default", "\(am.engineAvailability)"))
        do {
            try am.setEngineAvailability(.none)
            rows.append(("e.livekit_setEngineAvailability_none", "ok, now \(am.engineAvailability)"))
            try am.setEngineAvailability(.default)
        } catch {
            rows.append(("e.livekit_setEngineAvailability_none", "threw \(error)"))
        }
        let s = RTCAudioSession.sharedInstance()
        rows.append(("e.stasel_RTCAudioSession.useManualAudio_default", "\(s.useManualAudio)"))
        rows.append(("e.stasel_RTCAudioSession.isAudioEnabled_default", "\(s.isAudioEnabled)"))
        return rows
    }

    // MARK: HS256 token for the dev server (devkey/secret), microphone only

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func devToken(identity: String, room: String, sources: [String]) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": "devkey", "sub": identity, "nbf": now - 10, "exp": now + 900,
            "video": ["room": room, "roomJoin": true, "canPublish": true, "canSubscribe": true,
                      "canPublishSources": sources],
        ]
        let h = b64url(try! JSONSerialization.data(withJSONObject: header))
        let p = b64url(try! JSONSerialization.data(withJSONObject: claims))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(h).\(p)".utf8), using: SymmetricKey(data: Data("secret".utf8)))
        return "\(h).\(p).\(b64url(Data(mac)))"
    }
}
