import SwiftUI
import WebRTC

// Same stasel WebRTC usage as PoCVoice, without LiveKit: the size baseline.
@main
struct PoCVoiceNoLKApp: App {
    init() {
        RTCInitializeSSL()
        let f = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                         decoderFactory: RTCDefaultVideoDecoderFactory())
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        let pc = f.peerConnection(with: cfg,
                                  constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                                  delegate: nil)
        print("NoLK pc:", pc != nil)
    }
    var body: some Scene { WindowGroup { Text("PoC (no LiveKit)") } }
}
