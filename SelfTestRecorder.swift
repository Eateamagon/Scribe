//
//  Scribe — self-tests for GIF recording
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers

extension AppDelegate {
    /// `--selftest-gif`. Owned by the recorder work; see Recorder.swift.
    func runRecorderSelfTest() {
        Diag.log("SELFTEST-GIF: not written yet")
        NSApp.terminate(nil)
    }
}
