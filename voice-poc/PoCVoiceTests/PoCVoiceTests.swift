@testable import PoCVoice
import XCTest

/// All WebRTC / LiveKit calls live in the app module (Probe); the test bundle links neither framework, so the
/// test bundle itself cannot introduce a second copy of any class.
/// Every finding is printed as "POC_RESULT <key>: <value>" so the workflow can grep it from the test log.
final class PoCVoiceTests: XCTestCase {
    func report(_ rows: [(String, String)]) {
        for (k, v) in rows {
            let line = "POC_RESULT \(k): \(v)"
            print(line)
            NSLog("%@", line)
        }
    }

    // (a) both stacks initialise in the same process
    func testA_bothInitialiseInOneProcess() async throws {
        let rows = await Probe.checkBothInitialise()
        report(rows)
        XCTAssertTrue(rows.contains { $0.0 == "a.stasel_peer_connection" && $0.1 == "created" })
        XCTAssertTrue(rows.contains { $0.0 == "a.livekit_local_audio_track" })
    }

    // (b) no duplicate ObjC class names between WebRTC.framework and LiveKitWebRTC.framework
    func testB_noDuplicateObjCClasses() async throws {
        let (rows, overlap) = await Probe.checkDuplicateClasses()
        report(rows)
        XCTAssertEqual(overlap, 0, "duplicate ObjC classes between the two WebRTC frameworks")
    }

    // (d) connect to a local dev livekit-server (URL given by the workflow), publish the microphone only
    func testD_connectAndPublishMicrophone() async throws {
        guard let url = ProcessInfo.processInfo.environment["POC_LK_URL"], !url.isEmpty else {
            report([("d.connect", "SKIPPED (no POC_LK_URL)")])
            throw XCTSkip("no server")
        }
        let (rows, connected) = await Probe.connectAndPublish(url: url)
        report(rows)
        XCTAssertTrue(connected)
    }

    // (e) audio-session control APIs compiled against SDK 2.19.0 / stasel 125
    func testE_audioSessionControls() throws {
        report(Probe.audioSessionControls())
    }
}
