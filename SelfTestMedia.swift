//
//  Scribe — self-tests for rendering, crop, spotlight and GIF encoding
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers

extension AppDelegate {
    /// `--selftest-media`. Owned by the media work; see Media.swift.
    func runMediaSelfTest() {
        let guide = Guide()
        guard let step = Self.appendSyntheticGifStep(to: guide) else {
            Diag.log("SELFTEST-MEDIA FAILED: synthetic gif step"); NSApp.terminate(nil); return
        }
        let spec = step.renderSpec(number: 1)
        let still = FrameRenderer.still(spec)
        let frame = FrameRenderer.frame(spec, at: 1.6)
        let started = Date()
        let gif = MediaPreparer.gif(spec, preset: .web)
        let count = gif.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            .map(CGImageSourceGetCount) ?? 0
        Diag.log(String(format: "SELFTEST-MEDIA smoke: still=%@ frame=%@ gif=%d bytes, %d frames, %.2fs",
                        still.map { "\($0.width)x\($0.height)" } ?? "nil",
                        frame.map { "\($0.width)x\($0.height)" } ?? "nil",
                        gif?.count ?? 0, count, Date().timeIntervalSince(started)))
        if let gif { try? gif.write(to: guide.folder.appendingPathComponent("smoke.gif")) }
        if let frame { _ = Img.writePNG(frame, to: guide.folder.appendingPathComponent("smoke-frame.png")) }
        Diag.log(still != nil && frame != nil && count > 1
                 ? "SELFTEST-MEDIA PASSED — \(guide.folder.path)" : "SELFTEST-MEDIA FAILED: smoke")
        NSApp.terminate(nil)
    }
}
