//
//  Scribe — self-tests for GIF recording
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers

/// A clock the self-test moves by hand, so a 15 s clip takes no time at all.
private final class FakeClock {
    var now = 0.0
}

extension AppDelegate {

    // MARK: --selftest-gif
    //
    // Real Fn presses and real clicks cannot be synthesised — CGEventPost is
    // invisible to the global monitor (CLAUDE.md, "You cannot self-test the
    // click path"). So this drives `GifRecorder` and `FnMonitor` directly,
    // with invented frames, pointer samples, clicks and time, then exports a
    // guide holding a GIF step every way there is and checks what came out.
    // `--live` adds ~3 s from the real stream when Screen Recording allows.

    func runRecorderSelfTest() {
        Diag.log("SELFTEST-GIF: starting")
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what); Diag.log("SELFTEST-GIF check FAILED: \(what)") }
        }

        exerciseFnDebounce(check)
        guard let screen = NSScreen.screens.first else {
            Diag.log("SELFTEST-GIF FAILED: no screen"); NSApp.terminate(nil); return
        }
        exerciseRecorder(on: screen, check)

        Task { @MainActor in
            await self.exerciseQuickGif(check)
            await self.exerciseGifExports(check)
            if CommandLine.arguments.contains("--live") { await self.exerciseLiveClip() }
            Diag.log(failures.isEmpty
                     ? "SELFTEST-GIF PASSED"
                     : "SELFTEST-GIF FAILED: \(failures.count) check(s) — first: \(failures[0])")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
        }
    }

    /// Quick GIF: the countdown fires once after its count and not at all
    /// when cancelled; the clipboard item a finished Quick GIF produces
    /// carries the GIF, a file URL to it and an <img>, and fits the email
    /// budget. Built, not written — the real clipboard is left alone.
    private func exerciseQuickGif(_ check: (Bool, String) -> Void) async {
        let countdown = GifCountdown()
        countdown.tick = 0.05
        var fired = 0
        countdown.start(seconds: 3, on: NSScreen.screens.first) { fired += 1 }
        check(countdown.isRunning, "the countdown is running after start")
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(fired == 1 && !countdown.isRunning, "the countdown fired once (\(fired))")

        // A slow one to photograph, on its first number.
        let photo = GifCountdown()
        photo.tick = 5
        photo.start(seconds: 3, on: NSScreen.screens.first) {}
        await studioSnapshot(photo.window, named: "countdown-shot.png")
        photo.cancel()

        var cancelledFired = false
        countdown.start(seconds: 3, on: NSScreen.screens.first) { cancelledFired = true }
        countdown.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(!cancelledFired, "a cancelled countdown does not start a GIF")

        let g = Guide()
        guard let step = Self.appendSyntheticGifStep(to: g), let folder = step.clipFolderURL,
              let gif = await MediaPreparer.gifAsync(step.renderSpec(number: 1),
                                                     preset: Export.emailGIFPreset)
        else { check(false, "a GIF for the clipboard"); return }
        let file = folder.appendingPathComponent("clipboard.gif")
        try? gif.write(to: file)
        let item = Self.clipboardItem(gif: gif, file: file, alt: step.displayText)
        let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)
        let frames = item.data(forType: gifType)
            .flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            .map(CGImageSourceGetCount) ?? 0
        let html = item.string(forType: .html) ?? ""
        Diag.log("SELFTEST-GIF: quick GIF clipboard — \(gif.count / 1024) KB, \(frames) frames, "
                 + "types \(item.types.map(\.rawValue))")
        check(frames > 1, "the clipboard GIF is animated")
        check(item.string(forType: .fileURL) == file.absoluteString
              && FileManager.default.fileExists(atPath: file.path), "the clipboard file URL")
        check(html.hasPrefix("<img") && html.contains("data:image/gif;base64,"), "the clipboard <img>")
        check(gif.count <= Export.emailBudget.perGIF, "the clipboard GIF fits the email budget")
    }

    /// The Fn debounce on invented times: a proper hold, a brush of the key,
    /// and a hold with a one-poll flicker in it.
    private func exerciseFnDebounce(_ check: (Bool, String) -> Void) {
        let monitor = FnMonitor()
        var downs = 0, ups = 0
        monitor.onDown = { downs += 1 }
        monitor.onUp = { ups += 1 }
        let script: [(Bool, Double)] = [
            (true, 0.00), (true, 0.10), (true, 0.16),          // down at 150 ms
            (false, 0.50), (false, 0.55), (false, 0.59),       // up at 80 ms
            (true, 1.00), (true, 1.10), (false, 1.12),         // 120 ms brush: nothing
            (false, 1.30),
            (true, 2.00), (true, 2.20),                        // second hold
            (false, 2.30), (true, 2.35),                       // 50 ms flicker: no up
            (false, 2.40), (false, 2.50),                      // real release
        ]
        var afterFirstHold = (0, 0)
        for (i, (raw, t)) in script.enumerated() {
            monitor.evaluate(raw: raw, at: t)
            if i == 5 { afterFirstHold = (downs, ups) }
        }
        Diag.log("SELFTEST-GIF: Fn debounce — \(downs) down / \(ups) up "
                 + "(first hold \(afterFirstHold.0)/\(afterFirstHold.1))")
        check(afterFirstHold == (1, 1), "first hold should give one down and one up")
        check(downs == 2 && ups == 2, "brush and flicker must not count (got \(downs)/\(ups))")
    }

    /// The synthetic screen with the green block `progress` of the way
    /// across, at the same height as a mid-window control.
    private static func syntheticClipFrame(_ progress: CGFloat) -> CGImage? {
        guard let base = syntheticFrame(), let ctx = Img.bitmap(width: base.width, height: base.height)
        else { return nil }
        let w = CGFloat(base.width), h = CGFloat(base.height)
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.20, green: 0.80, blue: 0.40, alpha: 1))
        ctx.fill(Geo.drawRect(Self.blockRect(progress), in: w, h))
        return ctx.makeImage()
    }

    /// Normalised to the whole synthetic screen, top-left origin.
    private static func blockRect(_ progress: CGFloat) -> CGRect {
        CGRect(x: 0.10 + 0.70 * progress, y: 0.50, width: 0.08, height: 0.10)
    }

    private func exerciseRecorder(on screen: NSScreen, _ check: (Bool, String) -> Void) {
        let scratch = Guide()
        scratch.title = "GIF Recorder Self Test"
        let clock = FakeClock()
        let recorder = GifRecorder()
        recorder.clock = { clock.now }
        var capFired = 0
        recorder.onCap = { capFired += 1 }

        let size = screen.frame.size
        // A "window" in the middle of the screen, in screen-local points.
        let region = CGRect(x: size.width * 0.12, y: size.height * 0.18,
                            width: size.width * 0.66, height: size.height * 0.64)
        func global(_ localNorm: CGPoint) -> CGPoint {
            CGPoint(x: screen.frame.minX + localNorm.x * size.width,
                    y: screen.frame.maxY - localNorm.y * size.height)
        }
        /// A rect normalised to the screen → Accessibility coordinates.
        func axRect(_ norm: CGRect) -> CGRect {
            let local = CGRect(x: norm.minX * size.width, y: norm.minY * size.height,
                               width: norm.width * size.width, height: norm.height * size.height)
            return CGRect(x: screen.frame.minX + local.minX,
                          y: Geo.primaryTop - (screen.frame.maxY - local.minY),
                          width: local.width, height: local.height)
        }
        /// Screen-normalised → region-normalised, for sampling a still.
        func inRegion(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x * size.width - region.minX) / region.width,
                    y: (p.y * size.height - region.minY) / region.height)
        }
        let context = ClickTarget(label: "", windowTitle: "Animated Window", appName: "Finder",
                                  bundleID: "com.apple.finder", frame: nil, windowFrame: nil)
        let clipLength = 4.0
        func frame(at t: Double) -> CGImage? {
            Self.syntheticClipFrame(CGFloat(min(t / clipLength, 1)))
        }
        let displayID: CGDirectDisplayID = 4242
        let expectedWidth = Int((region.width * 1600 / size.width).rounded())

        // ── A: a 4 s clip with two clicks, one of them then double-clicked ──
        clock.now = 100
        let numberA = scratch.reserveFileNumber()
        check(recorder.begin(number: numberA, guideFolder: scratch.folder, displayID: displayID,
                             region: region, screen: screen, context: context,
                             seed: frame(at: 0)), "clip A begins")
        let button = CGRect(x: 0.22, y: 0.38, width: 0.16, height: 0.07)
        let target = ClickTarget(label: "New Folder", windowTitle: "Animated Window",
                                 appName: "Finder", bundleID: "com.apple.finder",
                                 frame: axRect(button), windowFrame: nil)
        for tick in 1...400 {                               // 10 ms steps
            let t = Double(tick) / 100
            clock.now = 100 + t
            if tick % 3 == 0 {                              // ~30 Hz pointer
                recorder.samplePointer(global(CGPoint(x: 0.2 + 0.5 * t / clipLength, y: 0.5)))
            }
            if tick % 5 == 0, let f = frame(at: t) {        // 20 fps stream
                recorder.ingest(f, displayID: displayID)
                if tick == 300 {
                    // One frame is left in flight and the next arrives while
                    // it is encoding: it must be dropped, not queued. The
                    // clock goes back afterwards; nothing was kept at 3.1 s.
                    clock.now += 0.1
                    recorder.ingest(f, displayID: displayID)
                    clock.now -= 0.1
                }
                if tick == 100 { recorder.ingest(f, displayID: 7) }   // another display
                recorder.drainWrites()
            }
            if tick == 150 {
                recorder.addClick(at: global(CGPoint(x: button.midX, y: button.midY)),
                                  target: target, verb: "Click", preClickFrame: frame(at: t))
            }
            if tick == 250 {
                recorder.addClick(at: global(CGPoint(x: 0.6, y: 0.6)), target: context,
                                  verb: "Click", preClickFrame: frame(at: t))
            }
            if tick == 260 { recorder.updateLastClickVerb("Double-click") }
        }
        guard let a = recorder.finish(finalFrame: frame(at: clipLength)) else {
            check(false, "clip A finished with no result"); return
        }
        let times = a.data.frames.map(\.time)
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        Diag.log(String(format: "SELFTEST-GIF: clip A — %d frames, %d pointer samples, %d clicks, "
                        + "%d dropped busy, trim %.2f–%.2f, %dx%d px, still %dx%d",
                        a.data.frames.count, a.data.pointer.count, a.data.clicks.count,
                        a.framesDropped, a.clip.trimStart, a.clip.trimEnd,
                        Int(a.data.pixelSize.width), Int(a.data.pixelSize.height),
                        a.still.width, a.still.height))
        check(a.data.frames.count >= 30, "clip A kept ≥30 frames (got \(a.data.frames.count))")
        check(a.data.frames.count <= 42, "clip A sampled at ≤10 fps (got \(a.data.frames.count))")
        check(gaps.allSatisfy { $0 >= GifRecorder.minFrameInterval - 0.0001 },
              "frames at least 95 ms apart")
        check(a.framesDropped >= 1, "a frame arriving mid-encode is dropped")
        check(a.data.clicks.count == 2, "two clicks recorded (double-click merged)")
        check(a.data.clicks.last?.verb == "Double-click", "double-click relabels the clip click")
        check(a.verb == "Click" && a.label == "New Folder" && a.showHighlight,
              "first click gives the step its verb, label and highlight")
        check(abs(a.clip.trimStart - 0.5) < 0.001 && abs(a.clip.trimEnd - 4.0) < 0.001,
              "default trim 0.5–4.0 (got \(a.clip.trimStart)–\(a.clip.trimEnd))")
        check(a.target.map { $0.insetBy(dx: -0.01, dy: -0.01).contains(a.click) } ?? false,
              "click lands inside its target, in region space")
        check(Int(a.data.pixelSize.width) == expectedWidth,
              "frames are the region crop (\(Int(a.data.pixelSize.width)) vs \(expectedWidth) px)")
        check(a.still.width == Int(a.data.pixelSize.width)
              && a.still.height == Int(a.data.pixelSize.height),
              "still and frames are the same size")
        // The still must be the frame from just before the FIRST click: the
        // block is where it was at 1.5 s, and not where it was at 2.5 s.
        let at15 = Self.blockRect(CGFloat(1.5 / clipLength))
        let at25 = Self.blockRect(CGFloat(2.5 / clipLength))
        let green = Img.sample(a.still, at: inRegion(CGPoint(x: at15.midX, y: at15.midY)))
        let later = Img.sample(a.still, at: inRegion(CGPoint(x: at25.midX, y: at25.midY)))
        check((green?.g ?? 0) > 150 && (green?.r ?? 255) < 120,
              "still shows the pre-click frame (block at 1.5 s)")
        check((later?.g ?? 255) < 150, "still is not a later frame")
        let clipFolder = scratch.folder.appendingPathComponent(a.clip.folder)
        check(ClipData.load(from: clipFolder)?.frames.count == a.data.frames.count,
              "clip.json round-trips")
        if let firstFile = a.data.frames.first,
           let decoded = Img.readPNG(clipFolder.appendingPathComponent(firstFile.file)) {
            check(decoded.width == a.still.width, "frame file matches the still")
        } else { check(false, "first frame file readable") }

        let stepA = scratch.appendGif(number: a.number, still: a.still, click: a.click,
                                      target: a.target, appName: a.appName,
                                      windowTitle: a.windowTitle, elementLabel: a.label,
                                      verb: a.verb, clip: a.clip, showHighlight: a.showHighlight)
        check(stepA?.media == .gif && stepA?.renderSpec(number: 1).rendersAsGIF == true,
              "step A appended as a GIF step")
        Diag.log("SELFTEST-GIF: step A text = \(stepA?.autoText ?? "nil")")

        // ── B: the 15 s cap, in invented time ──
        clock.now = 200
        let numberB = scratch.reserveFileNumber()
        recorder.begin(number: numberB, guideFolder: scratch.folder, displayID: displayID,
                       region: region, screen: screen, context: context, seed: frame(at: 0))
        for tick in 1...320 {                               // 50 ms steps to 16 s
            let t = Double(tick) / 20
            clock.now = 200 + t
            recorder.samplePointer(global(CGPoint(x: 0.3 + 0.01 * CGFloat(tick % 30), y: 0.4)))
            if let f = frame(at: t.truncatingRemainder(dividingBy: clipLength)) {
                recorder.ingest(f, displayID: displayID)
                recorder.drainWrites()
            }
            if tick == 40 {
                recorder.addClick(at: global(CGPoint(x: 0.5, y: 0.5)), target: context,
                                  verb: "Click", preClickFrame: frame(at: 2))
            }
        }
        clock.now = 216
        let b = recorder.finish(finalFrame: frame(at: 0))
        Diag.log(String(format: "SELFTEST-GIF: clip B (cap) — cap fired %d×, duration %.2f s, "
                        + "%d frames, last at %.2f s",
                        capFired, b?.data.duration ?? -1, b?.data.frames.count ?? 0,
                        b?.data.frames.last?.time ?? -1))
        check(capFired == 1, "15 s cap fires exactly once (fired \(capFired))")
        check(b?.data.duration == GifRecorder.maxDuration, "capped clip is 15 s long")
        check((b?.data.frames.last?.time ?? 99) < GifRecorder.maxDuration,
              "no frame recorded past the cap")
        check((b?.data.pointer.last?.time ?? 99) < GifRecorder.maxDuration,
              "no pointer sample past the cap")

        // ── C: a 0.4 s brush with no click leaves nothing behind ──
        clock.now = 300
        let numberC = scratch.reserveFileNumber()
        recorder.begin(number: numberC, guideFolder: scratch.folder, displayID: displayID,
                       region: region, screen: screen, context: context, seed: frame(at: 0))
        clock.now = 300.2
        if let f = frame(at: 1) { recorder.ingest(f, displayID: displayID) }
        clock.now = 300.4
        let c = recorder.finish(finalFrame: frame(at: 2))
        let folderC = scratch.folder.appendingPathComponent(String(format: "gif-%03d", numberC))
        check(c == nil, "0.4 s no-click hold is discarded")
        check(!FileManager.default.fileExists(atPath: folderC.path), "discarded clip folder removed")

        // ── D: a 2 s watch-only hold ──
        clock.now = 400
        let numberD = scratch.reserveFileNumber()
        recorder.begin(number: numberD, guideFolder: scratch.folder, displayID: displayID,
                       region: region, screen: screen, context: context, seed: frame(at: 0))
        for tick in 1...40 {
            clock.now = 400 + Double(tick) / 20
            recorder.samplePointer(global(CGPoint(x: 0.4, y: 0.4 + 0.005 * CGFloat(tick))))
            if let f = frame(at: Double(tick) / 20) {
                recorder.ingest(f, displayID: displayID)
                recorder.drainWrites()
            }
        }
        if let d = recorder.finish(finalFrame: frame(at: 2)) {
            let stepD = scratch.appendGif(number: d.number, still: d.still, click: d.click,
                                          target: d.target, appName: d.appName,
                                          windowTitle: d.windowTitle, elementLabel: d.label,
                                          verb: d.verb, clip: d.clip,
                                          showHighlight: d.showHighlight)
            Diag.log("SELFTEST-GIF: clip D (no click) — \(d.data.frames.count) frames, "
                     + "text = \(stepD?.autoText ?? "nil"), highlight \(d.showHighlight)")
            check(!d.showHighlight && d.verb == "Watch", "no-click clip: no highlight, verb Watch")
            check(stepD?.autoText == "Watch in Finder", "no-click text reads “Watch in Finder”")
            check(abs(d.clip.trimStart) < 0.001 && abs(d.clip.trimEnd - d.data.duration) < 0.001,
                  "no-click trim is the whole clip")
            check(d.still.width == Int(d.data.pixelSize.width)
                  && d.still.height == Int(d.data.pixelSize.height),
                  "no-click still is the last frame, same size")
        } else {
            check(false, "2 s no-click hold produced a step")
        }
        check(scratch.count == 2, "exactly the two kept clips became steps (got \(scratch.count))")
        Diag.log("SELFTEST-GIF: recorder guide at \(scratch.folder.path)")
    }

    // MARK: Exports

    private func exerciseGifExports(_ check: (Bool, String) -> Void) async {
        let g = Guide()
        g.title = "GIF Export Self Test"
        guard let frame = Self.syntheticFrame(),
              let gifStep = Self.appendSyntheticGifStep(to: g),
              g.append(image: frame, click: CGPoint(x: 0.72, y: 0.66), target: nil,
                       appName: "Finder", windowTitle: "Documents", elementLabel: "",
                       verb: "Right-click") != nil
        else { check(false, "build the export guide"); return }
        gifStep.note = "Drag the green block across the window."
        let folder = g.folder
        func count(_ needle: String, in hay: String) -> Int {
            hay.components(separatedBy: needle).count - 1
        }
        func write(_ text: String, _ name: String) {
            try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        // HTML
        var started = Date()
        let html = Export.html(g)
        write(html, "gif-selftest.html")
        Diag.log(String(format: "SELFTEST-GIF: html %d bytes in %.2f s (%d gif, %d picture)",
                        html.utf8.count, Date().timeIntervalSince(started),
                        count("data:image/gif", in: html), count("<picture>", in: html)))
        check(count("data:image/gif", in: html) == 1, "html embeds one GIF")
        check(count("<picture>", in: html) == 1
              && html.contains("prefers-reduced-motion: reduce"), "html GIF sits in a <picture>")

        started = Date()
        let htmlAsync = await Export.htmlAsync(g)
        Diag.log(String(format: "SELFTEST-GIF: htmlAsync %d bytes in %.2f s, identical to sync: %@",
                        htmlAsync.utf8.count, Date().timeIntervalSince(started),
                        htmlAsync == html ? "yes" : "no"))
        check(count("data:image/gif", in: htmlAsync) == 1, "htmlAsync embeds the GIF")

        // Email
        let email = Export.emailHTML(g)
        write(email, "gif-selftest-email.html")
        let gifBytes = Self.embeddedData(in: email, prefix: "data:image/gif;base64,")
        let frames = gifBytes.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            .map(CGImageSourceGetCount) ?? 0
        let width = gifBytes.flatMap(Export.pixelWidth(of:)) ?? 0
        Diag.log("SELFTEST-GIF: email \(email.utf8.count) bytes — <style \(count("<style", in: email)), "
                 + "class= \(count("class=", in: email)), gif \(count("data:image/gif", in: email)) "
                 + "(\(gifBytes?.count ?? 0) bytes, \(frames) frames, \(width) px wide), "
                 + "jpeg \(count("data:image/jpeg", in: email))")
        check(count("<style", in: email) == 0 && count("class=", in: email) == 0,
              "email has no <style> and no classes")
        check(count("data:image/gif", in: email) == 1, "email embeds exactly one GIF")
        check((gifBytes?.count ?? .max) < 1_500_000 && frames > 1, "email GIF animates, under 1.5 MB")
        check(width > 0 && width <= 600 && email.contains("width=\"\(width)\""),
              "email GIF is ≤600 px with width = pixel width")
        let sizes = Self.pxValues(of: "font-size", in: email)
        let heights = Self.pxValues(of: "line-height", in: email)
        Diag.log("SELFTEST-GIF: email font sizes \(sizes.sorted()), line heights \(heights.sorted())")
        check(sizes.isSubset(of: [12, 15, 20]), "email keeps to three font sizes")
        check(heights.isSubset(of: [5, 18, 22, 26]), "email keeps to three text line heights")

        // Email with the budget forced tiny: JPEG still plus the note.
        Export.emailBudget = Export.EmailBudget(perGIF: 2_000, message: 10_000_000)
        let tiny = Export.emailHTML(g)
        Export.emailBudget = Export.EmailBudget(perGIF: 1_500_000, message: 1)
        let full = Export.emailHTML(g)
        Export.emailBudget = .standard
        write(tiny, "gif-selftest-email-fallback.html")
        Diag.log("SELFTEST-GIF: email over per-GIF budget — gif \(count("data:image/gif", in: tiny)), "
                 + "jpeg \(count("data:image/jpeg", in: tiny)); over message budget — "
                 + "gif \(count("data:image/gif", in: full)), jpeg \(count("data:image/jpeg", in: full))")
        check(count("data:image/gif", in: tiny) == 0 && count("data:image/jpeg", in: tiny) == 2
              && tiny.contains("(animation in the web version)"),
              "per-GIF budget falls back to the JPEG still with a note")
        check(count("data:image/gif", in: full) == 0
              && full.contains("(animation in the web version)"),
              "message budget falls back too")

        let asyncEmail = await Export.emailHTMLAsync(g)
        check(count("data:image/gif", in: asyncEmail) == 1, "emailHTMLAsync embeds the GIF")
        let copied = await Export.copyForEmailAsync(g)
        let board = NSPasteboard.general.string(forType: .html)?.utf8.count ?? 0
        Diag.log("SELFTEST-GIF: copyForEmailAsync \(copied) bytes, \(board) read back")
        check(copied > 0 && copied == board, "copyForEmailAsync puts the email on the clipboard")

        // Markdown, both doorways.
        for (name, useAsync) in [("markdown", false), ("markdown-async", true)] {
            let md = folder.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: md, withIntermediateDirectories: true)
                if useAsync { try await Export.markdownAsync(g, to: md) }
                else { try Export.markdown(g, to: md) }
            } catch { check(false, "\(name) export threw \(error)") }
            let gifURL = md.appendingPathComponent("images/step-001.gif")
            let mdFrames = CGImageSourceCreateWithURL(gifURL as CFURL, nil)
                .map(CGImageSourceGetCount) ?? 0
            let text = (try? String(contentsOf: md.appendingPathComponent("guide.md"),
                                    encoding: .utf8)) ?? ""
            Diag.log("SELFTEST-GIF: \(name) step-001.gif \(mdFrames) frames, "
                     + Self.fileSize(gifURL))
            check(mdFrames > 1, "\(name) writes an animated step-001.gif")
            check(text.contains("images/step-001.gif") && text.contains("images/step-002.png"),
                  "\(name) references the GIF and the PNG")
        }

        // PDF at every density; the filmstrip path runs for step 1.
        if let clip = gifStep.gif, let data = gifStep.clipData {
            let keys = KeyFrames.pick(clip, data).map { String(format: "%.2f", $0) }
            Diag.log("SELFTEST-GIF: key frames at \(keys.joined(separator: ", ")) s; "
                     + String(format: "media aspect gif %.3f, still %.3f",
                              Export.mediaAspect(gifStep), Export.mediaAspect(g.steps[1])))
        }
        check(Export.mediaAspect(gifStep) > 0 && Export.mediaAspect(g.steps[1]) > 0,
              "mediaAspect reads both steps")
        let row = Export.stripLayout(count: 4, aspect: 0.625, in: CGSize(width: 478, height: 130))
        let grid = Export.stripLayout(count: 4, aspect: 0.625, in: CGSize(width: 478, height: 600))
        Diag.log("SELFTEST-GIF: strip layout short box \(row.columns)x\(row.rows), "
                 + "tall box \(grid.columns)x\(grid.rows)")
        check(row.rows == 1 && grid.columns == 2 && grid.rows == 2,
              "filmstrip picks a row for a short box and 2×2 for a tall one")
        for density in Export.PageDensity.choices {
            let tag = density == .fit ? "fit" : "\(density.storageValue)up"
            let url = folder.appendingPathComponent("gif-selftest-\(tag).pdf")
            var failed: Error?
            started = Date()
            Export.pdf(g, to: url, density: density) { failed = $0 }
            let pages = CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
            let png = folder.appendingPathComponent("gif-selftest-\(tag)-p1.png")
            let rendered = Self.renderPDFPage(url, page: 1, to: png)
            Diag.log(String(format: "SELFTEST-GIF: pdf %@ — %d page(s), %@, %.2f s, page 1 → %@",
                            tag, pages, Self.fileSize(url), Date().timeIntervalSince(started),
                            rendered ? png.path : "not rendered"))
            check(failed == nil && pages >= 1, "pdf \(tag) renders")
        }
        Diag.log("SELFTEST-GIF: export guide at \(folder.path)")
    }

    // MARK: --live

    /// ~3 s from the real stream, full main screen, if Screen Recording is
    /// granted. Informational: skips (not fails) when it is not.
    private func exerciseLiveClip() async {
        guard let screen = NSScreen.main else { return }
        let displayID = Geo.displayID(of: screen)
        capture.start()
        var waited = 0
        while capture.frame(for: displayID) == nil, !capture.permissionDenied, waited < 40 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            capture.start()
            waited += 1
        }
        guard let seed = capture.frame(for: displayID) else {
            Diag.log("SELFTEST-GIF: --live skipped — no frame "
                     + (capture.permissionDenied ? "(Screen Recording refused)" : "after 6 s"))
            capture.stop()
            return
        }
        let live = Guide()
        live.title = "GIF Live Self Test"
        let recorder = gifRecorder
        recorder.begin(number: live.reserveFileNumber(), guideFolder: live.folder,
                       displayID: displayID, region: Geo.fullRegion(of: screen), screen: screen,
                       context: ClickTarget(appName: "Live"), seed: seed)
        let ticker = Timer(timeInterval: 1 / FnMonitor.tickRate, repeats: true) { _ in
            MainActor.assumeIsolated { recorder.samplePointer(NSEvent.mouseLocation) }
        }
        RunLoop.main.add(ticker, forMode: .common)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        ticker.invalidate()
        let result = recorder.finish(finalFrame: capture.frame(for: displayID))
        capture.stop()
        guard let result else { Diag.log("SELFTEST-GIF: --live produced no clip"); return }
        let clipFolder = live.folder.appendingPathComponent(result.clip.folder)
        let bytes = ((try? FileManager.default.contentsOfDirectory(atPath: clipFolder.path)) ?? [])
            .reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(
                atPath: clipFolder.appendingPathComponent($1).path)[.size] as? Int) ?? 0) }
        Diag.log(String(format: "SELFTEST-GIF: --live — %.2f s, %d frames kept, %d dropped busy, "
                        + "%.1f ms/frame, %dx%d px, %d bytes on disk",
                        result.data.duration, result.data.frames.count, result.framesDropped,
                        result.msPerFrame, Int(result.data.pixelSize.width),
                        Int(result.data.pixelSize.height), bytes))
    }

    // MARK: Helpers

    private static func embeddedData(in html: String, prefix: String) -> Data? {
        guard let start = html.range(of: prefix) else { return nil }
        let rest = html[start.upperBound...]
        let end = rest.firstIndex(of: "\"") ?? rest.endIndex
        return Data(base64Encoded: String(rest[..<end]))
    }

    /// Every distinct `<property>:<n>px` in the markup.
    private static func pxValues(of property: String, in html: String) -> Set<Int> {
        guard let re = try? NSRegularExpression(pattern: "\(property):([0-9]+)px") else { return [] }
        let ns = html as NSString
        return Set(re.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) })
    }

    private static func fileSize(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
        return "\(size ?? -1) bytes"
    }

    /// Page `page` (1-based) of a PDF as a 2× PNG, so it can be looked at —
    /// `sips` and Quick Look only ever render page one.
    static func renderPDFPage(_ url: URL, page: Int, to out: URL, scale: CGFloat = 2) -> Bool {
        guard let doc = CGPDFDocument(url as CFURL), let p = doc.page(at: page) else { return false }
        let box = p.getBoxRect(.mediaBox)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = Img.bitmap(width: w, height: h) else { return false }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(p)
        guard let image = ctx.makeImage() else { return false }
        return Img.writePNG(image, to: out)
    }
}
