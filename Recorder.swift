//
//  Scribe — Fn-held GIF recording
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GIF steps: how a hold becomes a step
//
// While a recording is running, holding Fn (🌐) records one step as footage:
//
//   Fn down (held ≥150 ms)   region decided from what is under the pointer,
//                            seeded with the newest pre-Fn frame
//   every stream frame       ≤10 fps kept, cropped, JPEG'd to gif-NNN/
//   every 1/30 s             pointer position, for the synthetic cursor
//   every click              a ClipClick; the FIRST also gives the step its
//                            still, text and highlight
//   Fn up (≥80 ms) or 15 s   clip.json written, one step appended, one prompt
//
// The capture stream is the same one still steps use — nothing restarts, so
// the first frame of the clip is already there when Fn goes down. See
// "The screenshot must come from before the click" in CLAUDE.md.
// ─────────────────────────────────────────────────────────────────────────────

extension Settings {
    /// Whether new clips draw the synthetic pointer. Per clip afterwards —
    /// the editor can flip it on any one step.
    var showPointerInNewGifs: Bool {
        get { UserDefaults.standard.object(forKey: "gifShowPointer") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "gifShowPointer") }
    }

    /// Whether a finished Quick GIF also goes on the clipboard, ready to paste
    /// into an email. On by default — it is what the Quick GIF was asked for.
    var copyQuickGifs: Bool {
        get { UserDefaults.standard.object(forKey: "gifCopyQuick") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "gifCopyQuick") }
    }

    /// The Globe-key notice is shown once, ever.
    var globeNoticeShown: Bool {
        get { UserDefaults.standard.bool(forKey: "gifGlobeNoticeShown") }
        set { UserDefaults.standard.set(newValue, forKey: "gifGlobeNoticeShown") }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Fn monitor
//
// Polled, not observed. A global `flagsChanged` monitor is a *keyboard*
// monitor, and those need Input Monitoring — a permission this app has never
// needed. Reading the modifier state needs nothing, and 30 Hz is plenty for a
// key that is held for seconds.
//
// Debounced both ways. Fn is also the key people brush on the way to an arrow
// key or Fn-F-key, and a clip starting on every brush would litter the guide;
// 150 ms of hold filters those out. 80 ms on release keeps one flicker of the
// flag from splitting a clip in two.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class FnMonitor {
    static let downAfter = 0.150
    static let upAfter = 0.080
    static let tickRate = 30.0

    /// The ONE place the Fn signal is read. `--probe-fn` logs all three
    /// candidates side by side; if a human run shows one of them lying on this
    /// machine, this is the line to change. `CGEventSource.keyState(…, 0x3F)`
    /// is the third candidate and is deliberately not OR'd in until a probe
    /// shows it adds something — a stuck key state would record forever.
    nonisolated static func fnIsDown() -> Bool {
        NSEvent.modifierFlags.contains(.function)
            || CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
    }

    /// Keys macOS stamps with the Fn flag even when Fn itself is not held:
    /// arrows, Home/End, Page Up/Down, forward delete, Help and F1–F12. Holding
    /// ↓ to scroll must not start a GIF. Reading key state needs no permission;
    /// if it ever reads all-false, this simply stops filtering.
    nonisolated static let flaggedKeys: [CGKeyCode] = [
        0x7B, 0x7C, 0x7D, 0x7E,                 // ← → ↓ ↑
        0x73, 0x77, 0x74, 0x79, 0x75, 0x72,     // Home End PgUp PgDn ⌦ Help
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61,     // F1–F6
        0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,     // F7–F12
    ]

    nonisolated static func flaggedKeyHeld() -> Bool {
        flaggedKeys.contains { CGEventSource.keyState(.combinedSessionState, key: $0) }
    }

    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// Every poll, down or not — the GIF recorder samples the pointer here.
    var onTick: (() -> Void)?
    /// Swappable for the self-test.
    var source: () -> Bool = { FnMonitor.fnIsDown() }

    private(set) var isDown = false
    private var pendingSince: Double?
    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        isDown = false
        pendingSince = nil
        // `.common` mode, on RunLoop.main: a default-mode timer stops firing
        // while a menu is open or anything is tracking the mouse, which is
        // precisely when somebody demonstrating a menu is holding Fn.
        let t = Timer(timeInterval: 1 / Self.tickRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isDown = false
        pendingSince = nil
    }

    private func poll() {
        var raw = source()
        // Only guards the *start* of a hold: once a clip is running, Fn+→ is
        // a real Fn press and must not end it.
        if raw, !isDown, Self.flaggedKeyHeld() { raw = false }
        evaluate(raw: raw, at: ProcessInfo.processInfo.systemUptime)
        onTick?()
    }

    /// The debounce on its own, so the self-test can drive it with invented
    /// times instead of a real key.
    func evaluate(raw: Bool, at now: Double) {
        guard raw != isDown else { pendingSince = nil; return }
        let since = pendingSince ?? now
        pendingSince = since
        guard now - since >= (raw ? Self.downAfter : Self.upAfter) else { return }
        isDown = raw
        pendingSince = nil
        if raw { onDown?() } else { onUp?() }
    }

    /// A click arrived with the Fn flag before the 150 ms had passed and has
    /// already started the clip itself. Count the key as down without firing
    /// `onDown` again, so the release still ends that clip.
    func assumeDown() {
        isDown = true
        pendingSince = nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GIF recorder
// ─────────────────────────────────────────────────────────────────────────────

/// What the background writer hands back. Locked rather than actor-isolated:
/// the main actor must be able to ask "is one in flight?" without awaiting.
private final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var frames: [ClipFrame] = []
    private var pixelSize = CGSize.zero
    private var seconds = 0.0
    private var failures = 0

    /// Claims the single in-flight slot, or says no.
    func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    func complete(_ frame: ClipFrame?, size: CGSize, took: Double) {
        lock.lock(); defer { lock.unlock() }
        busy = false
        seconds += took
        if let frame {
            frames.append(frame)
            if pixelSize == .zero { pixelSize = size }
        } else {
            failures += 1
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        busy = false; frames = []; pixelSize = .zero; seconds = 0; failures = 0
    }

    var snapshot: (frames: [ClipFrame], pixelSize: CGSize, seconds: Double, failures: Int) {
        lock.lock(); defer { lock.unlock() }
        return (frames, pixelSize, seconds, failures)
    }
}

@MainActor
final class GifRecorder {

    /// Everything `Guide.appendGif` needs, decided by the recorder.
    struct Result {
        var number: Int
        var still: CGImage
        var click: CGPoint
        var target: CGRect?
        var appName: String
        var windowTitle: String
        var label: String
        var verb: String
        var showHighlight: Bool
        var clip: GifClip
        var data: ClipData
        /// For the log and the self-test.
        var framesDropped: Int
        var msPerFrame: Double
    }

    static let maxDuration = 15.0
    /// 10 fps, with a little slack so a 20 fps stream keeps every other frame
    /// rather than beating against the boundary and keeping one in three.
    static let minFrameInterval = 0.095
    /// A no-click hold shorter than this is a brush of the key, not a demo.
    static let minHoldWithoutClick = 0.7

    /// Seconds, monotonic. Injectable so the self-test can run a 15 s clip in
    /// no time at all.
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// The 15 s cap was hit. The owner finishes the clip; the recorder only
    /// stops accepting input.
    var onCap: (() -> Void)?
    /// Copied into the new clip's `GifClip.showPointer`.
    var showPointer = true

    private(set) var isRecording = false
    private(set) var capped = false
    private(set) var displayID: CGDirectDisplayID = 0

    private var number = 0
    private var folder: URL?
    private var folderName = ""
    /// Screen-local points, top-left origin — the same kind of region
    /// `captureRegion` returns for a still step.
    private var region = CGRect.zero
    private var screen: NSScreen?
    private var fullSize = CGSize.zero
    private var startedAt = 0.0
    private var lastKept = -1.0
    private var keptCount = 0
    private var dropped = 0
    private var pointer: [PointerSample] = []
    private var clicks: [ClipClick] = []
    private var context = ClickTarget()
    private var firstTarget: ClickTarget?
    private var still: CGImage?

    private let sink = FrameSink()
    // One serial queue and one in-flight frame. A frame that arrives while the
    // previous one is still being encoded is dropped, not queued: a queue would
    // hold IOSurfaces from the stream's small pool (see `queueDepth`), and a
    // backlog would finish writing long after Fn was released.
    private let queue = DispatchQueue(label: "com.ethantruslow.scribe.gif", qos: .userInitiated)

    var elapsed: Double { isRecording ? min(clock() - startedAt, Self.maxDuration) : 0 }
    var hasClicks: Bool { !clicks.isEmpty }
    var clickCount: Int { clicks.count }
    /// Screen-local region, for the self-test's crop checks.
    var regionPoints: CGRect { region }

    /// Starts a clip into `<guideFolder>/gif-NNN/`. `number` comes from
    /// `guide.reserveFileNumber()`, so the clip folder and the still it will
    /// eventually get (`shot-NNN.png`) share a number. `seed` is the newest
    /// frame from before Fn went down — the screen as it was when the user
    /// decided to start.
    @discardableResult
    func begin(number: Int, guideFolder: URL, displayID: CGDirectDisplayID,
               region: CGRect, screen: NSScreen, context: ClickTarget,
               seed: CGImage?) -> Bool {
        guard !isRecording else { return false }
        let name = String(format: "gif-%03d", number)
        let url = guideFolder.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Diag.log("GIF: could not create \(name): \(error.localizedDescription)")
            return false
        }
        self.number = number
        self.folder = url
        self.folderName = name
        self.displayID = displayID
        self.region = region
        self.screen = screen
        self.fullSize = Geo.fullRegion(of: screen).size
        self.context = context
        firstTarget = nil
        still = nil
        pointer = []
        clicks = []
        lastKept = -1
        keptCount = 0
        dropped = 0
        capped = false
        sink.reset()
        startedAt = clock()
        isRecording = true
        if let seed { enqueue(seed, at: 0) }
        Diag.log("GIF: clip \(name) started on display \(displayID), region "
                 + "\(Int(region.width))x\(Int(region.height)) pt, seed \(seed != nil)")
        return true
    }

    /// A stream frame. Only the clip's own display counts: the clip is locked
    /// to one region on one screen, and a frame from the projector would be a
    /// different picture entirely.
    func ingest(_ frame: CGImage, displayID: CGDirectDisplayID) {
        guard isRecording, !capped, displayID == self.displayID else { return }
        let t = clock() - startedAt
        if t >= Self.maxDuration { hitCap(); return }
        guard lastKept < 0 || t - lastKept >= Self.minFrameInterval else { return }
        enqueue(frame, at: t)
    }

    /// Called every FnMonitor tick with the global (NSEvent) pointer location.
    /// Also where the cap is noticed when the screen is idle: ScreenCaptureKit
    /// sends no frames for unchanged pixels, so `ingest` alone could miss it.
    func samplePointer(_ global: CGPoint) {
        guard isRecording, !capped else { return }
        let t = clock() - startedAt
        if t >= Self.maxDuration { hitCap(); return }
        let point = normalized(global)
        // A resting pointer needs two samples, not thirty a second: keep the
        // first and slide the last one's time forward.
        if pointer.count >= 2, pointer[pointer.count - 1].point == point,
           pointer[pointer.count - 2].point == point {
            pointer[pointer.count - 1].time = t
        } else {
            pointer.append(PointerSample(time: t, point: point))
        }
    }

    /// A click made while the clip is recording. `preClickFrame` is
    /// `capture.frame(for: displayID)` read at click time — the same "newest
    /// frame is from before the click" rule a still step uses — and becomes the
    /// step's still if this is the first click.
    func addClick(at global: CGPoint, target: ClickTarget, verb: String,
                  preClickFrame: CGImage?) {
        guard isRecording, !capped, let screen else { return }
        let t = clock() - startedAt
        let point = normalized(global)
        let normTarget = target.frame
            .map { Geo.localRect(axRect: $0, on: screen) }
            .map { Geo.normalize(localRect: $0, in: region) }
        clicks.append(ClipClick(time: t, point: point, target: normTarget,
                                label: target.label, verb: verb))
        // The cursor is exactly on the click at the moment of the click, even
        // if the last 30 Hz sample was a few pixels short of it.
        pointer.append(PointerSample(time: t, point: point))
        if clicks.count == 1 {
            firstTarget = target
            if let preClickFrame,
               let cropped = Img.crop(preClickFrame, to: region, fullSize: fullSize) {
                still = Img.downscale(cropped)
            }
        }
    }

    /// Second half of a double-click: the clip keeps one click, relabelled.
    func updateLastClickVerb(_ verb: String) {
        guard !clicks.isEmpty else { return }
        clicks[clicks.count - 1].verb = verb
    }

    /// Ends the clip. nil when there is nothing worth a step — a brush of the
    /// key, or no frames at all — in which case the folder is gone too.
    ///
    /// `finalFrame` is the newest stream frame at release. The frame written
    /// just before might have been dropped for being mid-encode; without this
    /// the GIF could end one change short of what the click actually did.
    func finish(finalFrame: CGImage? = nil) -> Result? {
        guard isRecording, let folder else { return nil }
        isRecording = false
        let duration = min(clock() - startedAt, Self.maxDuration)

        // Blocks for at most the one frame in flight (tens of ms). clip.json
        // must list only files that are completely on disk.
        queue.sync {}
        if !capped, let finalFrame, duration - lastKept >= Self.minFrameInterval {
            enqueue(finalFrame, at: duration)
            queue.sync {}
        }
        let snap = sink.snapshot

        func discard(_ why: String) -> Result? {
            try? FileManager.default.removeItem(at: folder)
            Diag.log("GIF: \(folderName) discarded — \(why)")
            return nil
        }
        if clicks.isEmpty && duration < Self.minHoldWithoutClick {
            return discard(String(format: "%.2f s hold with no clicks", duration))
        }
        guard !snap.frames.isEmpty else { return discard("no frames arrived") }

        // No click: the step's picture is how the clip ends. A click whose
        // pre-click frame was missing takes the newest recorded frame from
        // before it instead — the frame at the end would show the result of
        // the click under a highlight that says "click here".
        var stillImage = still
        if stillImage == nil {
            let before = clicks.first.flatMap { click in
                snap.frames.last(where: { $0.time <= click.time })
            }
            if let pick = before ?? snap.frames.last {
                stillImage = Img.readPNG(folder.appendingPathComponent(pick.file))
            }
        }
        guard let stillImage else { return discard("no still") }

        let data = ClipData(frames: snap.frames, pointer: pointer, clicks: clicks,
                            duration: duration, pixelSize: snap.pixelSize,
                            regionPoints: region.size)
        guard data.write(to: folder) else { return discard("clip.json could not be written") }

        let trim = GifClip.defaultTrim(for: data)
        let first = clicks.first
        let who = firstTarget ?? context
        let ms = snap.frames.isEmpty ? 0 : snap.seconds * 1000 / Double(snap.frames.count)
        Diag.log(String(format: "GIF: %@ finished — %.2f s, %d frame(s) kept, %d dropped busy, "
                        + "%d click(s), %.0f ms/frame, %dx%d px",
                        folderName, duration, snap.frames.count, dropped, clicks.count, ms,
                        Int(snap.pixelSize.width), Int(snap.pixelSize.height)))
        return Result(number: number, still: stillImage,
                      click: first?.point ?? pointer.last?.point ?? CGPoint(x: 0.5, y: 0.5),
                      target: first?.target,
                      appName: who.appName, windowTitle: who.windowTitle,
                      label: first?.label ?? "",
                      // "Watch in Finder" reads as an instruction; a click
                      // verb on a step with no click would be a lie.
                      verb: first?.verb ?? "Watch",
                      showHighlight: first != nil,
                      clip: GifClip(folder: folderName, trimStart: trim.start,
                                    trimEnd: trim.end, showPointer: showPointer),
                      data: data, framesDropped: dropped, msPerFrame: ms)
    }

    /// For the self-test: wait for the frame in flight, as if the stream had
    /// paused long enough for it to land.
    func drainWrites() { queue.sync {} }

    // MARK: Internals

    private func normalized(_ global: CGPoint) -> CGPoint {
        guard let screen else { return CGPoint(x: 0.5, y: 0.5) }
        return Geo.normalize(localPoint: Geo.localPoint(global, on: screen), in: region)
    }

    private func hitCap() {
        guard !capped else { return }
        capped = true
        Diag.log("GIF: \(folderName) reached the \(Int(Self.maxDuration)) s cap")
        onCap?()
    }

    private func enqueue(_ frame: CGImage, at time: Double) {
        guard let folder, sink.reserve() else { dropped += 1; return }
        lastKept = time
        keptCount += 1
        let name = String(format: "frame-%04d.jpg", keptCount)
        let url = folder.appendingPathComponent(name)
        let region = self.region, fullSize = self.fullSize, sink = self.sink
        queue.async {
            let started = ProcessInfo.processInfo.systemUptime
            var written: ClipFrame?
            var size = CGSize.zero
            // Same crop, same downscale as the still, so every normalised
            // coordinate on the step means the same thing on every frame.
            if let cropped = Img.crop(frame, to: region, fullSize: fullSize) {
                let small = Img.downscale(cropped)
                size = CGSize(width: small.width, height: small.height)
                if Img.writeJPEG(small, to: url, quality: 0.85) {
                    written = ClipFrame(file: name, time: time)
                }
            }
            sink.complete(written, size: size,
                          took: ProcessInfo.processInfo.systemUptime - started)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Recording HUD
//
// "● GIF 3.2 s / 15 s" near the top of the screen being recorded. Scribe's
// own windows never appear in footage — the stream's SCContentFilter excludes
// the whole Scribe *application*, not a list of window IDs (see
// `Capture.start`), so a panel created mid-recording is excluded as well.
// It ignores the mouse, so it can never catch a click meant for the app
// underneath, and it can never become key.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class GifHUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?
    private var lastText = ""

    private static let size = NSSize(width: 200, height: 32)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: GifHUD.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .ignoresCycle, .stationary]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: GifHUD.size))
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: blur.widthAnchor, constant: -16),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    func show(on screen: NSScreen?) {
        hideTimer?.invalidate()
        hideTimer = nil
        place(on: screen)
        update(elapsed: 0)
        panel.orderFrontRegardless()
    }

    /// Only touches the label when the tenth of a second changes; this is
    /// called 30 times a second.
    func update(elapsed: Double) {
        let text = String(format: "GIF  %.1f s / %d s", elapsed, Int(GifRecorder.maxDuration))
        guard text != lastText else { return }
        lastText = text
        label.attributedStringValue = Self.styled(text)
    }

    /// A message that clears itself — "stopped at 15 s" and similar.
    func flash(_ message: String, on screen: NSScreen?, for seconds: Double = 2.2) {
        place(on: screen)
        lastText = ""
        label.attributedStringValue = Self.styled(message)
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        lastText = ""
        panel.orderOut(nil)
    }

    private func place(on screen: NSScreen?) {
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: visible.midX - GifHUD.size.width / 2,
                                     y: visible.maxY - GifHUD.size.height - 10))
    }

    private static func styled(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.10, alpha: 1),
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
        ])
        out.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
        ]))
        return out
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Quick GIF countdown
//
// "3, 2, 1" in the middle of the screen the pointer is on, so there is time to
// get the pointer and the window where the demo starts. Scribe's own windows
// never reach the capture, and it is gone before the clip's first frame anyway.
// Click-through, never key: the setting-up clicks go to the app underneath.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class GifCountdown {
    private let panel: NSPanel
    private let number = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var remaining = 0
    private var done: (() -> Void)?

    /// Seconds per count. Only the self-test changes it.
    var tick: TimeInterval = 1

    private static let size = NSSize(width: 150, height: 150)

    var isRunning: Bool { timer != nil }
    /// For the self-test's photograph.
    var window: NSWindow { panel }

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: GifCountdown.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .ignoresCycle, .stationary]

        // A solid dark disc, not a material: over a light desktop the HUD
        // material came out light grey behind a white number — unreadable at
        // a glance, which is the only way a countdown gets read.
        let blur = NSView(frame: NSRect(origin: .zero, size: GifCountdown.size))
        blur.wantsLayer = true
        blur.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.88).cgColor
        blur.layer?.cornerRadius = GifCountdown.size.width / 2
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 3
        blur.layer?.borderColor = NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.10, alpha: 1).cgColor
        panel.contentView = blur
        // No fade: each number has to be on screen the instant it changes.
        panel.animationBehavior = .none

        number.font = .monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        number.textColor = .white
        number.alignment = .center
        let caption = NSTextField(labelWithString: "GIF")
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        caption.textColor = NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.10, alpha: 1)
        caption.alignment = .center
        let stack = NSStackView(views: [number, caption])
        stack.orientation = .vertical
        stack.spacing = -4
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])
    }

    /// Counts down from `seconds`, then calls `done` — after the panel is
    /// already off screen.
    func start(seconds: Int, on screen: NSScreen?, done: @escaping () -> Void) {
        cancel()
        remaining = max(seconds, 1)
        self.done = done
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: frame.midX - GifCountdown.size.width / 2,
                                     y: frame.midY - GifCountdown.size.height / 2))
        number.stringValue = "\(remaining)"
        panel.orderFrontRegardless()
        let t = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        // `.common`, so a menu held open does not stall the count.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        done = nil
        panel.orderOut(nil)
    }

    private func step() {
        remaining -= 1
        guard remaining <= 0 else { number.stringValue = "\(remaining)"; return }
        let finish = done
        cancel()
        finish?()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Globe key notice
//
// Out of the box, pressing 🌐 on its own opens the emoji picker (or switches
// input source, or starts dictation). Holding it to record a GIF works either
// way — but on release macOS does its own thing too, and a picker popping up
// over the demo reads as Scribe misbehaving. So the first recording on a Mac
// where the key does something says so, once, and offers ⌃⌥⌘F instead.
//
// A floating non-activating panel, never `runModal`: the recording has
// already started, and a modal from an LSUIElement app can open behind other
// windows while the app blocks (see "No modal dialogs, ever").
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class GlobeKeyNotice: NSObject {
    private var panel: PromptWindow?
    private var timer: Timer?

    /// `AppleFnUsageType` in com.apple.HIToolbox: 0 Do Nothing, 1 Change Input
    /// Source, 2 Show Emoji & Symbols, 3 Start Dictation. A Mac that has never
    /// touched the setting has no key at all, and ships as emoji.
    static func globeUsage() -> Int {
        UserDefaults(suiteName: "com.apple.HIToolbox")?
            .object(forKey: "AppleFnUsageType") as? Int ?? 2
    }

    static func describe(_ usage: Int) -> String {
        switch usage {
        case 0: return "Do Nothing"
        case 1: return "Change Input Source"
        case 3: return "Start Dictation"
        default: return "Show Emoji & Symbols"
        }
    }

    /// Shows the notice if this Mac needs it and it has not been shown before.
    func showIfNeeded() {
        guard !Settings.shared.globeNoticeShown else { return }
        let usage = Self.globeUsage()
        guard usage != 0 else { return }
        Settings.shared.globeNoticeShown = true
        Diag.log("GIF: Globe key is set to \(Self.describe(usage)) — showing the one-time notice")
        show(usage: usage)
    }

    func show(usage: Int) {
        let width: CGFloat = 400, height: CGFloat = 168
        let panel = PromptWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Pressing a button here must not pull keyboard focus away from the
        // app being demonstrated.
        panel.becomesKeyOnlyIfNeeded = true

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        panel.contentView = blur

        let heading = NSTextField(labelWithString: "Hold Fn (🌐) while clicking to record a GIF step")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString:
            "On this Mac, pressing 🌐 is set to “\(Self.describe(usage))”, which will also "
            + "happen when you let go. Set System Settings › Keyboard › “Press 🌐 key to” "
            + "to “Do Nothing”, or press ⌃⌥⌘F to start and stop a GIF instead.")
        body.font = .systemFont(ofSize: 11.5)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = width - 32

        let settings = NSButton(title: "Keyboard Settings…", target: self,
                                action: #selector(openKeyboardSettings))
        settings.bezelStyle = .rounded
        let ok = NSButton(title: "OK", target: self, action: #selector(dismiss))
        ok.bezelStyle = .rounded
        let buttons = NSStackView(views: [settings, ok])
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        // Top right, clear of the HUD in the middle and of whatever is being
        // demonstrated, which is usually in the middle too.
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: visible.maxX - width - 16, y: visible.maxY - height - 16))
        panel.orderFrontRegardless()
        self.panel = panel

        // It is information, not a question; it should not sit there all day.
        timer = Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    @objc func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        dismiss()
    }

    @objc func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
