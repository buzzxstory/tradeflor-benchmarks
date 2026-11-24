import SwiftUI

@main
struct PoCVoiceApp: App {
    init() {
        // Running in the app too (not only in tests) so a plain simulator launch also exercises both stacks.
        Probe.initStasel()
    }
    var body: some Scene { WindowGroup { Text("PoC voice") } }
}
