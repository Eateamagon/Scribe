//
//  Scribe — click-by-click tutorial recorder for macOS
//
//  A local recreation of what scribehow.com does: record a workflow, get a
//  numbered, screenshotted, shareable how-to guide out the other end.
//  NOT the commercial product, and nothing to do with any AI "scribe".
//
//  Build:  bash build.sh
//

import Cocoa
import Carbon
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit
import CoreMedia
import VideoToolbox

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Global hotkeys (Carbon — needs NO permission)
//
// The one input path that keeps working when Accessibility and Screen
// Recording are both refused, which makes it the right place for "stop
// recording": you must always be able to stop.
// ─────────────────────────────────────────────────────────────────────────────

final class HotKeyCenter: @unchecked Sendable {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var installed = false
    private let lock = NSLock()

    private init() {}

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        lock.lock()
        let id = nextID
        nextID += 1
        handlers[id] = handler
        lock.unlock()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53435242) /* 'SCRB' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { refs.append(ref) }
        else { Diag.log("RegisterEventHotKey failed for code \(keyCode): \(status)") }
    }

    fileprivate func fire(_ id: UInt32) {
        lock.lock(); let handler = handlers[id]; lock.unlock()
        handler?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            // ByteCount is not exposed to Swift; MemoryLayout.size goes in raw.
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Named hotkey that KeyAtlas can list and rebind (see KeyAtlasBridge).
    func register(id: String, title: String, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        KeyAtlasBridge.publish(id: id, title: title, keyCode: Int(keyCode), eventFlags: KeyAtlasBridge.eventFlags(carbon: modifiers))
        guard let r = KeyAtlasBridge.resolve(id: id, keyCode: Int(keyCode), carbonModifiers: modifiers) else {
            Diag.log("hotkey \(id): turned off in KeyAtlas")
            return
        }
        if r.keyCode != Int(keyCode) || r.modifiers != modifiers { Diag.log("hotkey \(id): KeyAtlas override keyCode \(r.keyCode) mods \(r.modifiers)") }
        register(keyCode: UInt32(r.keyCode), modifiers: r.modifiers, handler: handler)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - KeyAtlas bridge
//
// Lets KeyAtlas (~/ClaudeCode/KeyAtlas) list and rebind these hotkeys, which
// Carbon otherwise keeps invisible to other apps. Each launch publishes
// "KeyAtlasManifest" in this app's defaults; KeyAtlas writes overrides to
// "KeyAtlasHotkey.<id>" as {keyCode, modifierFlags} (NSEvent flag bits), and
// {} means "turned off". Overrides take effect the next time the app launches.
// ─────────────────────────────────────────────────────────────────────────────

extension NSMenuItem {
    /// Shows the ⌃⌥⌘ hotkey this item fires — or KeyAtlas's replacement, or none if it was turned off.
    func applyHotKey(id: String, keyCode: Int) {
        let k = KeyAtlasBridge.menuKey(id: id, keyCode: keyCode, carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
        keyEquivalent = k.key
        keyEquivalentModifierMask = k.mask
    }
}

enum KeyAtlasBridge {
    private static var publishedThisLaunch = false

    /// Records a shortcut in the manifest. `scope` is "global" (rebindable) or "inApp" (listed only).
    static func publish(id: String, title: String, keyCode: Int, eventFlags: UInt, scope: String = "global") {
        let d = UserDefaults.standard
        var list = publishedThisLaunch ? ((d.array(forKey: "KeyAtlasManifest") as? [[String: Any]]) ?? []) : []
        publishedThisLaunch = true
        list.removeAll { ($0["id"] as? String) == id }
        list.append(["id": id, "title": title, "keyCode": keyCode, "modifierFlags": Int(eventFlags), "scope": scope])
        d.set(list, forKey: "KeyAtlasManifest")
    }

    /// The combo to register for `id`: KeyAtlas's override, else the default. nil = turned off.
    static func resolve(id: String, keyCode: Int, carbonModifiers: UInt32) -> (keyCode: Int, modifiers: UInt32)? {
        guard let o = UserDefaults.standard.dictionary(forKey: "KeyAtlasHotkey." + id) else { return (keyCode, carbonModifiers) }
        guard let k = o["keyCode"] as? Int, let f = o["modifierFlags"] as? Int, k >= 0 else { return nil }
        return (k, carbon(UInt(f)))
    }

    static func eventFlags(carbon m: UInt32) -> UInt {
        var f: UInt = 0
        if m & UInt32(shiftKey) != 0 { f |= 1 << 17 }
        if m & UInt32(controlKey) != 0 { f |= 1 << 18 }
        if m & UInt32(optionKey) != 0 { f |= 1 << 19 }
        if m & UInt32(cmdKey) != 0 { f |= 1 << 20 }
        return f
    }

    static func carbon(_ f: UInt) -> UInt32 {
        var m: UInt32 = 0
        if f & (1 << 17) != 0 { m |= UInt32(shiftKey) }
        if f & (1 << 18) != 0 { m |= UInt32(controlKey) }
        if f & (1 << 19) != 0 { m |= UInt32(optionKey) }
        if f & (1 << 20) != 0 { m |= UInt32(cmdKey) }
        return m
    }

    /// Menu key equivalent matching what's actually registered (letters and digits only).
    static func menuKey(id: String, keyCode: Int, carbonModifiers: UInt32) -> (key: String, mask: NSEvent.ModifierFlags) {
        guard let r = resolve(id: id, keyCode: keyCode, carbonModifiers: carbonModifiers),
              let ch = ansi[r.keyCode] else { return ("", []) }
        return (ch, NSEvent.ModifierFlags(rawValue: eventFlags(carbon: r.modifiers)))
    }

    private static let ansi: [Int: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l", 46: "m",
        45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - App delegate
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let guide = Guide()
    let capture = Capture()
    let prompt = PromptBox()
    let namePanel = GuideNamePanel()
    var editor: EditorWindowController?
    var library: LibraryWindowController?

    var statusItem: NSStatusItem!
    var mouseMonitor: Any?
    var displayTimer: Timer?

    var isRecording = false
    var sawFirstFrame = false

    /// Double-click arrives as two separate mouseDown events. Rather than two
    /// near-identical steps, the second one rewrites the first.
    var eraseAfterShot = false
    var expandAfterShot = false
    var lastStep: GuideStep?
    var lastClickAt = Date.distantPast
    var lastClickPoint = CGPoint.zero

    /// GIF steps: Fn held (or a Quick GIF, ⌃⌥⌘F) records one step as footage.
    let fnMonitor = FnMonitor()
    let gifRecorder = GifRecorder()
    let gifHUD = GifHUD()
    let globeNotice = GlobeKeyNotice()
    /// Started by ⌃⌥⌘F rather than by holding Fn — the Fn state is ignored
    /// until the hotkey is pressed again.
    var gifToggleMode = false
    /// The 15 s cap ended a clip while Fn was still held. Until Fn comes up,
    /// Fn-clicks are ordinary steps rather than the start of another clip.
    var fnCapped = false
    /// Quick GIF: ⌃⌥⌘F or the menu — a countdown, then a clip with no key held.
    let gifCountdown = GifCountdown()
    /// The recording was started only to take one Quick GIF, and stops when
    /// that clip is done.
    var quickSession = false
    static let quickCountdown = 3

    /// Clicks dropped this recording because the Record Clicks key was not held.
    var ignoredClicks = 0

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.start()
        Diag.log("Scribe launched from \(Bundle.main.bundlePath)")
        Diag.log("Accessibility trusted: \(AXInspector.isTrusted)")
        Diag.log("CGPreflightScreenCaptureAccess = \(CGPreflightScreenCaptureAccess())")
        AXInspector.configure()

        capture.onPermissionDenied = { [weak self] in
            Diag.log("Screen Recording refused (-3801) — recording stopped")
            self?.stopRecording(openEditor: false)
        }

        buildMainMenu()
        buildStatusItem()
        configureGifRecording()

        // ⌃⌥⌘R toggles recording, ⌃⌥⌘E opens the editor. Carbon hotkeys need no
        // permission, so they work even before anything has been granted.
        let mods = UInt32(controlKey | optionKey | cmdKey)
        HotKeyCenter.shared.register(id: "toggleRecording", title: "Start / Stop Recording", keyCode: 15, modifiers: mods) {   // R
            Task { @MainActor [weak self] in self?.toggleRecording() }
        }
        HotKeyCenter.shared.register(id: "openEditor", title: "Open Guide Editor", keyCode: 14, modifiers: mods) {   // E
            Task { @MainActor [weak self] in self?.openEditor() }
        }
        HotKeyCenter.shared.register(id: "openLibrary", title: "All Guides", keyCode: 5, modifiers: mods) {    // G
            Task { @MainActor [weak self] in self?.openLibrary() }
        }
        HotKeyCenter.shared.register(id: "newGuide", title: "New Guide", keyCode: 45, modifiers: mods) {   // N
            Task { @MainActor [weak self] in self?.startNewGuide() }
        }
        // ⌃⌥⌘F starts and stops a GIF step, for a Mac where holding Fn is
        // unreliable or already means something. HotKeyCenter fires on main.
        HotKeyCenter.shared.register(id: "quickGif", title: "Start / Stop GIF Step", keyCode: 3, modifiers: mods) { [weak self] in  // F
            MainActor.assumeIsolated { self?.quickGif() }
        }

        for (id, title, key, flags) in [("editor.play", "Play / Pause GIF step (editor)", 49, UInt(0)),
                                        ("editor.applyCrop", "Apply crop (editor)", 36, 0),
                                        ("editor.cancelCrop", "Cancel crop (editor)", 53, 0),
                                        ("editor.deleteStep", "Delete selected step (editor)", 51, 0)] {
            KeyAtlasBridge.publish(id: id, title: title, keyCode: key, eventFlags: flags, scope: "inApp")
        }

        if CommandLine.arguments.contains("--probe-fn") { probeFn() }
        else if CommandLine.arguments.contains("--probe-browser") { probeBrowser() }
        else if CommandLine.arguments.contains("--selftest-media") { runMediaSelfTest() }
        else if CommandLine.arguments.contains("--selftest-gif") { runRecorderSelfTest() }
        else if CommandLine.arguments.contains("--shot-studio") { shotStudio() }
        else if CommandLine.arguments.contains("--shot-themes") { shotThemes() }
        else if CommandLine.arguments.contains("--shot-pdf") { shotPDF() }
        else if CommandLine.arguments.contains("--shot-nameprompt") { shotNamePrompt() }
        else if CommandLine.arguments.contains("--dump-context") { dumpContext() }
        else if CommandLine.arguments.contains("--shot-expanded") { shotEditor(expanded: true) }
        else if CommandLine.arguments.contains("--shot-library") { shotLibrary() }
        else if CommandLine.arguments.contains("--shot-erase") { shotEditor(thenErase: true) }
        else if CommandLine.arguments.contains("--shot-editor") { shotEditor() }
        else if CommandLine.arguments.contains("--selftest-offline") { runOfflineSelfTest() }
        else if CommandLine.arguments.contains("--selftest") { runSelfTest() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if gifRecorder.isRecording { endClip(presentPrompt: false) }
        prompt.commitCurrent()
        capture.stop()
        guide.save()
    }

    // MARK: Recording

    @objc func toggleRecording() {
        if isRecording { stopRecording(openEditor: true); return }

        // Ask for a name first, but only for a genuinely new guide. Coming back
        // to one that already has steps is a resume, and being asked to rename
        // it every time you pause would be maddening.
        guard guide.isEmpty, Settings.shared.askForGuideName else {
            startRecording(); return
        }
        namePanel.ask(suggestion: Self.suggestedName()) { [weak self] name in
            guard let self else { return }
            guard let name else {
                Diag.log("recording cancelled at the name prompt")
                return
            }
            self.guide.title = name
            self.refreshStatusItem()
            self.startRecording()
        }
    }

    /// What the field offers if you just press return. A date beats "Untitled
    /// Guide" for finding things again later.
    ///
    /// Built with `setLocalizedDateFormatFromTemplate`, not a literal format
    /// string. In a `DateFormatter` pattern every unquoted letter is a
    /// specifier, so the obvious `"MMMM d guide"` renders as
    /// "September 2 24612862026" — g, u, i, d and e are all fields. The
    /// template API takes only field letters and cannot make that mistake, and
    /// it gets the locale's day/month order right for free.
    static func suggestedName() -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMd")
        return "Guide — " + f.string(from: Date())
    }

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        sawFirstFrame = false
        lastStep = nil
        lastClickAt = .distantPast

        capture.start()
        // Displays get plugged in, unplugged, and put to sleep mid-recording;
        // start() is idempotent and only does work when something changed.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.capture.start()
                if !self.sawFirstFrame { self.refreshStatusItem() }
            }
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleClick(event) }
        }

        gifToggleMode = false
        fnCapped = false
        ignoredClicks = 0
        fnMonitor.start()
        let gate = Settings.shared.clickGate
        if gate != .off, !quickSession {
            gifHUD.flash(gate.hint, on: Geo.screen(containing: NSEvent.mouseLocation), for: 2.5)
        }

        Diag.log("recording started (guide has \(guide.count) step(s))")
        refreshStatusItem()
        globeNotice.showIfNeeded()
    }

    /// `keepPrompt` leaves an open step prompt alone — a Quick GIF session
    /// ends the moment its clip does, while its prompt is still being typed in.
    func stopRecording(openEditor showEditor: Bool, keepPrompt: Bool = false) {
        guard isRecording else { return }
        // Cleared first: `endClip` below must not try to end the session again.
        quickSession = false
        gifCountdown.cancel()
        // A clip in progress becomes its step before anything shuts down —
        // the capture stream included, since the clip's last frame comes from
        // it. No prompt: the recording is ending and the editor is next.
        if gifRecorder.isRecording { endClip(presentPrompt: false) }
        fnMonitor.stop()
        gifToggleMode = false
        fnCapped = false
        gifHUD.hide()
        isRecording = false
        if !keepPrompt { prompt.commitCurrent() }

        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        displayTimer?.invalidate()
        displayTimer = nil
        capture.stop()

        Diag.log("recording stopped with \(guide.count) step(s)")
        refreshStatusItem()
        library?.reload()
        if showEditor && !guide.isEmpty { self.openEditor() }
    }

    /// Runs on every click anywhere except inside Scribe itself — a global
    /// monitor never sees our own app's events, which is why clicking the
    /// prompt box does not become a step.
    func handleClick(_ event: NSEvent) {
        guard isRecording else { return }
        // Clicks during a Quick GIF countdown are setting up the demo.
        if gifCountdown.isRunning { return }
        // Fn-held clicks are already deliberate, so GIF clips skip the gate.
        if routeToClip(event) { return }
        // The event's own flags, or the live state in case they lag a frame.
        let gate = Settings.shared.clickGate
        guard gate.allows(rawFlags: UInt(event.modifierFlags.rawValue) | ClickGate.liveFlags()) else {
            ignoredClicks += 1
            // Once per recording, so a forgotten key is noticed — not on every
            // click, which is exactly the navigating this setting is for.
            if ignoredClicks == 1 {
                gifHUD.flash("Not recorded — \(gate.hint.lowercased())",
                             on: Geo.screen(containing: NSEvent.mouseLocation), for: 2.0)
            }
            return
        }
        let point = NSEvent.mouseLocation
        guard let screen = Geo.screen(containing: point) else { return }
        let displayID = Geo.displayID(of: screen)

        guard let frame = capture.frame(for: displayID) else {
            Diag.log("click on display \(displayID) with no frame yet — step skipped")
            return
        }
        if !sawFirstFrame { sawFirstFrame = true; refreshStatusItem() }

        // The Accessibility query has to happen now: a moment later the click
        // has already changed the frontmost app and the element under it.
        let target = AXInspector.inspect(at: point)
        let verb = self.verb(for: event)

        // Second half of a double-click: upgrade the previous step in place.
        let elapsed = Date().timeIntervalSince(lastClickAt)
        let moved = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y)
        if event.type == .leftMouseDown, event.clickCount >= 2,
           elapsed < 0.6, moved < 6, let previous = lastStep {
            previous.verb = "Double-click"
            previous.invalidateThumbnail()
            guide.save()
            NotificationCenter.default.post(name: Guide.didChange, object: nil)
            lastClickAt = Date()
            prompt.present(number: guide.count,
                           placeholder: previous.autoText,
                           near: point,
                           avoiding: target.frame) { [weak previous] text in
                if !text.isEmpty { previous?.note = text }
                Task { @MainActor [weak self] in self?.guide.save(); self?.editor?.refresh() }
            }
            return
        }

        // What part of the display this step should show.
        guard let region = captureRegion(for: target, on: screen) else {
            Diag.once("scopeskip",
                      "click ignored — outside the app this recording is scoped to")
            return
        }
        guard let cropped = Img.crop(frame, to: region,
                                     fullSize: Geo.fullRegion(of: screen).size) else {
            Diag.log("crop failed for region \(region) — step skipped")
            return
        }

        let localClick = Geo.localPoint(point, on: screen)
        let normClick = Geo.normalize(localPoint: localClick, in: region)
        let normTarget = target.frame
            .map { Geo.localRect(axRect: $0, on: screen) }
            .map { Geo.normalize(localRect: $0, in: region) }

        guard let step = guide.append(image: cropped,
                                      click: normClick,
                                      target: normTarget,
                                      appName: target.appName,
                                      windowTitle: target.windowTitle,
                                      elementLabel: target.label,
                                      verb: verb)
        else { return }
        if let page = target.pageFrame {
            guide.setPage(Geo.normalize(localRect: Geo.localRect(axRect: page, on: screen), in: region),
                          crop: Settings.shared.hideBrowserChrome, click: normClick,
                          at: guide.count - 1)
        }

        lastStep = step
        lastClickAt = Date()
        lastClickPoint = point
        refreshStatusItem()

        let number = guide.count
        prompt.present(number: number,
                       placeholder: step.autoText,
                       near: point,
                       avoiding: target.frame) { [weak self, weak step] text in
            guard let self, let step else { return }
            if !text.isEmpty {
                step.note = text
                self.guide.save()
                NotificationCenter.default.post(name: Guide.didChange, object: nil)
            }
        }
    }

    /// The screen-local region this step should capture, or nil when the click
    /// falls outside a single-app recording and should be dropped entirely.
    ///
    /// Anything that cannot be resolved — no Accessibility, an app with no
    /// window chain, a frame that is stale or offscreen — falls back to the
    /// whole screen. A guide with too much in the picture beats a guide with a
    /// missing step.
    func captureRegion(for target: ClickTarget, on screen: NSScreen) -> CGRect? {
        let full = Geo.fullRegion(of: screen)

        switch Settings.shared.captureScope {
        case .wholeScreen:
            return full

        case .clickedWindow:
            guard let axWindow = target.windowFrame else { return full }
            return Geo.sanitize(region: Geo.localRect(axRect: axWindow, on: screen),
                                on: screen) ?? full

        case .app(let bundleID, _):
            guard target.bundleID == bundleID else { return nil }
            let axWindow = target.windowFrame
                ?? AXInspector.focusedWindowFrame(ofBundleID: bundleID)
            guard let axWindow else { return full }
            return Geo.sanitize(region: Geo.localRect(axRect: axWindow, on: screen),
                                on: screen) ?? full
        }
    }

    /// "Click", plus whatever the reader would otherwise have no way to know.
    func verb(for event: NSEvent, gate: ClickGate = Settings.shared.clickGate) -> String {
        if event.type == .rightMouseDown { return "Right-click" }
        if event.type == .otherMouseDown { return "Middle-click" }

        var parts: [String] = []
        var mods = event.modifierFlags
        if let held = gate.strippedModifier(rawFlags: UInt(mods.rawValue)) { mods.remove(held) }
        if mods.contains(.command) { parts.append("Command") }
        if mods.contains(.shift)   { parts.append("Shift") }
        if mods.contains(.option)  { parts.append("Option") }
        if mods.contains(.control) { parts.append("Control") }
        guard !parts.isEmpty else { return "Click" }
        return parts.joined(separator: "-") + "-click"
    }

    // MARK: GIF steps
    //
    // The recorder does the work (Recorder.swift); this is the wiring: which
    // clicks belong to a clip, when one starts and ends, and the one prompt
    // the finished step gets.

    func configureGifRecording() {
        capture.onFrame = { [weak self] id, image in
            self?.gifRecorder.ingest(image, displayID: id)
        }
        fnMonitor.onDown = { [weak self] in self?.fnWentDown() }
        fnMonitor.onUp = { [weak self] in self?.fnWentUp() }
        fnMonitor.onTick = { [weak self] in self?.gifTick() }
        gifRecorder.onCap = { [weak self] in self?.clipHitCap() }
    }

    private func fnWentDown() {
        guard isRecording, !gifToggleMode, !fnCapped, !gifRecorder.isRecording else { return }
        beginClip()
    }

    private func fnWentUp() {
        fnCapped = false
        guard !gifToggleMode, gifRecorder.isRecording else { return }
        endClip()
    }

    private func gifTick() {
        guard gifRecorder.isRecording else { return }
        gifRecorder.samplePointer(NSEvent.mouseLocation)
        gifHUD.update(elapsed: gifRecorder.elapsed)
    }

    private func clipHitCap() {
        // Fn may well still be held. Without this the next Fn-click would
        // start a second clip straight away, which nobody asked for.
        if !gifToggleMode { fnCapped = fnMonitor.isDown }
        endClip(flash: "GIF stopped at \(Int(GifRecorder.maxDuration)) s")
    }

    /// ⌃⌥⌘F: the same clip as holding Fn, started and stopped by the hotkey.
    /// Quick GIF (⌃⌥⌘F or the menu): a 3 s countdown, then a clip that runs
    /// without Fn until ⌃⌥⌘F again or the 15 s cap. Pressing it during the
    /// countdown cancels. Works without a recording in progress: one is
    /// started for the clip and stopped when it ends, leaving one GIF step.
    @objc func quickGif() {
        if gifCountdown.isRunning {
            gifCountdown.cancel()
            Diag.log("GIF: quick GIF countdown cancelled")
            if quickSession { stopRecording(openEditor: false) }
            refreshStatusItem()
            return
        }
        if gifRecorder.isRecording { endClip(); return }

        if !isRecording {
            // No name prompt: it would eat the countdown. A dated name beats
            // "Untitled Guide" in the library, and it can be renamed later.
            if guide.isEmpty, guide.title == "Untitled Guide" { guide.title = Self.suggestedName() }
            quickSession = true
            startRecording()
        }
        let screen = Geo.screen(containing: NSEvent.mouseLocation)
        Diag.log("GIF: quick GIF countdown started")
        gifCountdown.start(seconds: Self.quickCountdown, on: screen) { [weak self] in
            self?.quickCountdownFinished()
        }
        refreshStatusItem()
    }

    private func quickCountdownFinished() {
        guard isRecording else { return }
        if beginClip() {
            gifToggleMode = true
        } else {
            gifHUD.flash("GIF did not start — see the log", on: Geo.screen(containing: NSEvent.mouseLocation))
            if quickSession { stopRecording(openEditor: false) }
        }
        refreshStatusItem()
    }

    /// The region is decided NOW, from what is under the pointer — the same
    /// `captureRegion` a still step uses, so a GIF step and the still steps
    /// around it are cropped alike. Returns false if no clip started.
    @discardableResult
    func beginClip() -> Bool {
        guard isRecording, !gifRecorder.isRecording else { return false }
        let point = NSEvent.mouseLocation
        guard let screen = Geo.screen(containing: point) else { return false }
        let displayID = Geo.displayID(of: screen)
        let target = AXInspector.inspect(at: point)
        guard let region = clipRegion(for: target, on: screen) else {
            Diag.log("GIF: not started — the pointer is outside the app this recording is "
                     + "scoped to, and that app has no window to use instead")
            return false
        }
        // The step prompt is a key panel. Left open, whatever the demo types
        // would go into it instead of into the app being recorded.
        prompt.commitCurrent()

        let seed = capture.frame(for: displayID)
        let number = guide.reserveFileNumber()
        gifRecorder.showPointer = Settings.shared.showPointerInNewGifs
        guard gifRecorder.begin(number: number, guideFolder: guide.folder,
                                displayID: displayID, region: region, screen: screen,
                                context: target, seed: seed)
        else { return false }
        if seed == nil {
            Diag.log("GIF: no frame yet on display \(displayID) — the clip starts with the next one")
        }
        gifRecorder.samplePointer(point)
        // A double-click has to stay inside the clip, never reach back and
        // relabel the step before it.
        lastStep = nil
        gifHUD.show(on: screen)
        refreshStatusItem()
        return true
    }

    /// `captureRegion`, except that `.app` scope with the pointer elsewhere
    /// is not a reason to drop the clip: Fn-down is not a click, and the
    /// pointer is often on its way into the app. That app's own window is the
    /// region instead, when there is one.
    func clipRegion(for target: ClickTarget, on screen: NSScreen) -> CGRect? {
        if let region = captureRegion(for: target, on: screen) { return region }
        guard case .app(let bundleID, _) = Settings.shared.captureScope,
              let window = AXInspector.focusedWindowFrame(ofBundleID: bundleID)
        else { return nil }
        return Geo.sanitize(region: Geo.localRect(axRect: window, on: screen), on: screen)
    }

    /// Finishes the clip and appends its step. `presentPrompt` is false when
    /// something else is about to take over — the recording stopping, or a
    /// plain click that will open its own prompt.
    func endClip(presentPrompt: Bool = true, flash: String? = nil) {
        guard gifRecorder.isRecording else { return }
        let screen = Geo.screen(containing: NSEvent.mouseLocation)
        let finalFrame = capture.frame(for: gifRecorder.displayID)
        let result = gifRecorder.finish(finalFrame: finalFrame)
        // Toggle mode means this clip came from Quick GIF, not an Fn hold.
        let wasQuick = gifToggleMode
        gifToggleMode = false
        if let flash { gifHUD.flash(flash, on: screen) } else { gifHUD.hide() }
        defer { refreshStatusItem() }

        // A Quick GIF session exists for this one clip. Ended after the step
        // and its prompt are up; `keepPrompt` lets the prompt outlive it.
        defer { if quickSession { stopRecording(openEditor: false, keepPrompt: true) } }

        guard let result else { removeGuideFolderIfUnused(); return }
        guard let step = guide.appendGif(number: result.number, still: result.still,
                                         click: result.click, target: result.target,
                                         appName: result.appName,
                                         windowTitle: result.windowTitle,
                                         elementLabel: result.label, verb: result.verb,
                                         clip: result.clip,
                                         showHighlight: result.showHighlight)
        else { return }
        if let page = result.pageRect {
            guide.setPage(page, crop: Settings.shared.hideBrowserChrome,
                          click: result.data.clicks.first?.point, at: guide.count - 1)
        }
        lastStep = nil
        lastClickAt = .distantPast
        library?.reload()
        if wasQuick, Settings.shared.copyQuickGifs { copyGifToClipboard(step, on: screen) }

        guard presentPrompt else { return }
        prompt.present(number: guide.count,
                       placeholder: step.autoText,
                       near: NSEvent.mouseLocation,
                       avoiding: nil) { [weak self, weak step] text in
            guard let self, let step else { return }
            if !text.isEmpty {
                step.note = text
                self.guide.save()
                NotificationCenter.default.post(name: Guide.didChange, object: nil)
            }
        }
    }

    /// A discarded first clip must not leave an empty session folder behind
    /// ("Session folders are created lazily" in CLAUDE.md).
    private func removeGuideFolderIfUnused() {
        guard guide.isEmpty,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: guide.folder.path),
              contents.filter({ $0 != ".DS_Store" }).isEmpty
        else { return }
        try? FileManager.default.removeItem(at: guide.folder)
    }

    /// Clicks that belong to a clip rather than becoming steps of their own.
    /// Returns true when the click has been dealt with.
    private func routeToClip(_ event: NSEvent) -> Bool {
        // The click's own flag or the live state: either is enough to say Fn
        // is down. `FnMonitor.fnIsDown` is where the signal source is chosen.
        let fnHeld = event.modifierFlags.contains(.function) || FnMonitor.fnIsDown()

        if gifRecorder.isRecording {
            if gifToggleMode || fnHeld { addClipClick(event); return true }
            // Fn is already up; the 80 ms release debounce just has not fired.
            // The click is after the clip: close it, and let the click be an
            // ordinary step with its own (single) prompt.
            endClip(presentPrompt: false)
            return false
        }

        // Fn-click before the 150 ms hold registered: start the clip on the
        // click itself rather than losing the click to a still step.
        guard fnHeld, !fnCapped, !FnMonitor.flaggedKeyHeld(), beginClip() else { return false }
        fnMonitor.assumeDown()
        addClipClick(event)
        return true
    }

    private func addClipClick(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let elapsed = Date().timeIntervalSince(lastClickAt)
        let moved = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y)
        if event.type == .leftMouseDown, event.clickCount >= 2,
           elapsed < 0.6, moved < 6, gifRecorder.hasClicks {
            gifRecorder.updateLastClickVerb("Double-click")
            lastClickAt = Date()
            return
        }
        // Frame first, then Accessibility, exactly as `handleClick` does: the
        // click is already changing the screen and the element under it.
        let frame = capture.frame(for: gifRecorder.displayID)
        let target = AXInspector.inspect(at: point)
        gifRecorder.addClick(at: point, target: target, verb: verb(for: event),
                             preClickFrame: frame)
        if frame != nil && !sawFirstFrame { sawFirstFrame = true }
        lastClickAt = Date()
        lastClickPoint = point
    }

    /// Puts a GIF step on the clipboard for pasting into Gmail: sized with
    /// the email preset (600 px, budgeted), encoded off the main thread.
    ///
    /// Three flavours, because which one a compose window takes is up to the
    /// browser: the GIF itself, a file URL to a copy of it (what Finder's Copy
    /// puts there, which Chrome and Safari paste into Gmail as an inline
    /// image), and an `<img>` for anything that only reads HTML. Which one
    /// Gmail actually uses — and whether it stays animated — needs a human.
    func copyGifToClipboard(_ step: GuideStep, on screen: NSScreen?) {
        guard let index = guide.steps.firstIndex(where: { $0 === step }),
              let folder = step.clipFolderURL else { return }
        let spec = step.renderSpec(number: index + 1)
        gifHUD.flash("Copying GIF…", on: screen, for: 10)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            guard let gif = await MediaPreparer.gifAsync(spec, preset: Export.emailGIFPreset) else {
                // Over the email budget even after shrinking: say so rather
                // than leaving yesterday's clipboard in place silently.
                Diag.log("GIF: quick GIF too large for email — not copied")
                self.gifHUD.flash("GIF too long for email — shorten it in the editor", on: screen)
                return
            }
            let file = folder.appendingPathComponent("clipboard.gif")
            try? gif.write(to: file, options: .atomic)
            let item = Self.clipboardItem(gif: gif, file: file, alt: step.displayText)
            let board = NSPasteboard.general
            board.clearContents()
            board.writeObjects([item])
            Diag.log(String(format: "GIF: quick GIF copied to the clipboard — %d KB, %.2f s",
                            gif.count / 1024, Date().timeIntervalSince(started)))
            self.gifHUD.flash("GIF copied — paste into Gmail with ⌘V", on: screen, for: 3)
        }
    }

    /// The pasteboard item for a copied GIF, separate so the self-test can
    /// check it without touching the real clipboard.
    static func clipboardItem(gif: Data, file: URL, alt: String) -> NSPasteboardItem {
        let width = Export.pixelWidth(of: gif) ?? 600
        let html = "<img width=\"\(width)\" alt=\"\(Export.escape(alt))\" "
            + "src=\"data:image/gif;base64,\(gif.base64EncodedString())\">"
        let item = NSPasteboardItem()
        item.setData(gif, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString(html, forType: .html)
        return item
    }

    @objc func toggleCopyQuickGifs() {
        Settings.shared.copyQuickGifs.toggle()
        Diag.log("copy quick GIFs to clipboard = \(Settings.shared.copyQuickGifs)")
        refreshStatusItem()
    }

    @objc func toggleShowPointerInGifs() {
        Settings.shared.showPointerInNewGifs.toggle()
        Diag.log("show pointer in new GIFs = \(Settings.shared.showPointerInNewGifs)")
        refreshStatusItem()
    }

    /// "Quick GIF" / "Stop GIF" / "Cancel GIF Countdown" — the same ⌃⌥⌘F item
    /// at the top of the menu and in GIF Steps ▸.
    func quickGifItem() -> NSMenuItem {
        let title = gifCountdown.isRunning ? "Cancel GIF Countdown"
            : gifRecorder.isRecording ? "Stop GIF"
            : "Quick GIF (\(Self.quickCountdown) s countdown)"
        let item = NSMenuItem(title: title, action: #selector(quickGif), keyEquivalent: "f")
        item.applyHotKey(id: "quickGif", keyCode: 3)
        item.target = self
        item.toolTip = isRecording
            ? "Counts down \(Self.quickCountdown) s, then records a GIF step without holding Fn. "
              + "⌃⌥⌘F again to stop."
            : "Counts down \(Self.quickCountdown) s, then records one GIF step into “\(guide.title)” — "
              + "no recording needed. ⌃⌥⌘F again to stop."
        return item
    }

    /// "GIF Steps ▸" in the status menu.
    func buildGifItem() -> NSMenuItem {
        let item = NSMenuItem(title: "GIF Steps", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(disabled("Hold Fn while clicking to record a GIF step"))
        submenu.addItem(disabled("Release Fn to finish — \(Int(GifRecorder.maxDuration)) s at most"))
        submenu.addItem(.separator())

        submenu.addItem(quickGifItem())
        let copy = NSMenuItem(title: "Copy Quick GIFs to Clipboard",
                              action: #selector(toggleCopyQuickGifs), keyEquivalent: "")
        copy.target = self
        copy.state = Settings.shared.copyQuickGifs ? .on : .off
        copy.toolTip = "When a Quick GIF finishes, put it on the clipboard sized for email, "
            + "ready to paste into Gmail."
        submenu.addItem(copy)

        let pointer = NSMenuItem(title: "Show Pointer in New GIFs",
                                 action: #selector(toggleShowPointerInGifs), keyEquivalent: "")
        pointer.target = self
        pointer.state = Settings.shared.showPointerInNewGifs ? .on : .off
        pointer.toolTip = "Draw the pointer and click ripples in GIFs recorded from now on. "
            + "Each GIF step can still be switched in the editor."
        submenu.addItem(pointer)

        item.submenu = submenu
        return item
    }

    // MARK: Editor

    @objc func openEditor() {
        if editor == nil {
            let controller = EditorWindowController(guide: guide)
            controller.onNewGuide = { [weak self] in self?.startNewGuide() }
            editor = controller
        }
        editor?.show()
    }

    @objc func openLibrary() {
        if library == nil {
            let controller = LibraryWindowController(guide: guide)
            controller.onOpen = { [weak self] folder in self?.openGuide(at: folder) }
            controller.onNewGuide = { [weak self] in self?.startNewGuide() }
            library = controller
        }
        library?.show()
    }

    /// Makes a session folder the live guide. Refused while recording: swapping
    /// the guide out from under an in-progress recording would append the next
    /// click to whichever guide happened to win.
    func openGuide(at folder: URL) {
        guard !isRecording else {
            Diag.log("refused to open \(folder.lastPathComponent) — still recording")
            return
        }
        if folder == guide.folder && !guide.isEmpty { openEditor(); return }
        guard guide.load(from: folder) else {
            Diag.log("could not open \(folder.lastPathComponent)"); return
        }
        Diag.log("opened \(guide.count) step(s) from \(folder.lastPathComponent)")
        editor?.refresh()
        library?.reload()
        refreshStatusItem()
        openEditor()
    }

    /// Starts an empty guide. The current one is already on disk and appears in
    /// the library, so nothing is lost and nothing needs confirming.
    @objc func startNewGuide() {
        guard !isRecording else {
            Diag.log("refused to start a new guide — still recording")
            return
        }
        guard !guide.isEmpty else {
            Diag.log("new guide requested but the current one is already empty")
            editor?.reportStatus("This guide is already empty — press ⌃⌥⌘R to record.")
            return
        }
        let previous = guide.title
        let count = guide.count
        guide.startNew()
        editor?.refresh()
        library?.reload()
        refreshStatusItem()
        editor?.reportStatus("Started a new guide. “\(previous)” "
                             + "(\(count) step\(count == 1 ? "" : "s")) is in the library.")
        Diag.log("started a new guide; “\(previous)” parked with \(count) step(s)")
    }

    @objc func reopenLastGuide() {
        guard let folder = Guide.mostRecentFolder() else {
            Diag.log("no previous session to reopen"); return
        }
        if folder == guide.folder && !guide.isEmpty { openEditor(); return }
        guard guide.load(from: folder) else {
            Diag.log("could not reopen \(folder.lastPathComponent)"); return
        }
        Diag.log("reopened \(guide.count) step(s) from \(folder.lastPathComponent)")
        refreshStatusItem()
        openEditor()
    }

    // MARK: Status item

    /// Scribe runs as an accessory app with no menu bar — until the editor
    /// opens and switches the activation policy to `.regular`, at which point
    /// macOS shows whatever main menu we have. Without this, that menu is a
    /// bare "Scribe" with no Quit, no Close, and — the one that actually bites
    /// — no Edit menu, so copy and paste are dead in every text field.
    func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Scribe",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Scribe",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        refreshStatusItem()

        NotificationCenter.default.addObserver(
            forName: Guide.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatusItem() }
            }
    }

    func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        // A clip gets its own look — orange, and "GIF" in place of the count —
        // because releasing Fn is what ends it, and you need to be able to see
        // at a glance that one is running.
        let clip = gifRecorder.isRecording
        let symbol = isRecording ? "record.circle.fill" : "list.bullet.rectangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Scribe")
        image?.isTemplate = !isRecording
        button.image = image
        button.contentTintColor = clip
            ? NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.10, alpha: 1)
            : (isRecording ? NSColor(calibratedRed: 0.94, green: 0.16, blue: 0.35, alpha: 1) : nil)
        button.title = clip ? " GIF"
            : isRecording
                ? (sawFirstFrame ? " \(guide.count)" : " …")
                : (guide.isEmpty ? "" : " \(guide.count)")
        button.toolTip = clip ? (gifToggleMode ? "Scribe is recording a GIF step — ⌃⌥⌘F to finish"
                         : "Scribe is recording a GIF step — release Fn to finish")
            : isRecording ? "Scribe is recording — ⌃⌥⌘R to stop"
                + (Settings.shared.clickGate == .off ? "" : " · \(Settings.shared.clickGate.hint)")
                          : "Scribe — ⌃⌥⌘R to record"
        statusItem.menu = buildMenu()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let record = NSMenuItem(title: isRecording ? "Stop Recording" : "Start Recording",
                                action: #selector(toggleRecording), keyEquivalent: "r")
        record.applyHotKey(id: "toggleRecording", keyCode: 15)
        record.target = self
        menu.addItem(record)

        if isRecording && !sawFirstFrame {
            menu.addItem(disabled("   Waiting for the first screen frame…"))
        }
        menu.addItem(quickGifItem())

        let edit = NSMenuItem(title: "Open Guide Editor…",
                              action: #selector(openEditor), keyEquivalent: "e")
        edit.applyHotKey(id: "openEditor", keyCode: 14)
        edit.target = self
        edit.isEnabled = true
        menu.addItem(edit)

        let fresh = NSMenuItem(title: "New Guide",
                               action: #selector(startNewGuide), keyEquivalent: "n")
        fresh.applyHotKey(id: "newGuide", keyCode: 45)
        fresh.target = self
        fresh.isEnabled = !guide.isEmpty && !isRecording
        fresh.toolTip = guide.isEmpty
            ? "The current guide is already empty."
            : "Start an empty guide. “\(guide.title)” is saved and stays in the library."
        menu.addItem(fresh)

        let reopen = NSMenuItem(title: "Reopen Last Guide",
                                action: #selector(reopenLastGuide), keyEquivalent: "")
        reopen.target = self
        reopen.toolTip = "Load the most recent recording back into the editor."
        menu.addItem(reopen)

        let all = NSMenuItem(title: "All Guides…",
                             action: #selector(openLibrary), keyEquivalent: "g")
        all.applyHotKey(id: "openLibrary", keyCode: 5)
        all.target = self
        all.toolTip = "Every guide you have recorded, with the current one marked."
        menu.addItem(all)

        let askName = NSMenuItem(title: "Ask for a Name When Recording",
                                 action: #selector(toggleAskForName), keyEquivalent: "")
        askName.target = self
        askName.state = Settings.shared.askForGuideName ? .on : .off
        askName.toolTip = "Prompt for a guide name when a new recording starts."
        menu.addItem(askName)

        menu.addItem(buildThemeItem())

        menu.addItem(.separator())
        menu.addItem(buildCaptureScopeItem())
        let chrome = NSMenuItem(title: "Hide Browser Tabs & Address Bar",
                                action: #selector(toggleHideBrowserChrome), keyEquivalent: "")
        chrome.target = self
        chrome.state = Settings.shared.hideBrowserChrome ? .on : .off
        chrome.toolTip = "Crop steps in Chrome, Safari, Edge, Brave, Arc or Firefox to the web page. "
            + "Clicks on a tab or the address bar keep the whole window. "
            + "Each step can be switched back in the editor."
        menu.addItem(chrome)
        menu.addItem(buildClickGateItem())
        menu.addItem(buildGifItem())

        menu.addItem(.separator())
        menu.addItem(disabled(guide.isEmpty
            ? "No steps recorded"
            : "\(guide.count) step\(guide.count == 1 ? "" : "s") · \(guide.title)"))

        menu.addItem(.separator())
        menu.addItem(permissionItem(
            title: "Screen Recording",
            granted: capture.isRunning && !capture.permissionDenied,
            unknown: !isRecording,
            action: #selector(openScreenRecordingSettings)))
        let ask = NSMenuItem(title: "Request Screen Recording Access…",
                             action: #selector(requestScreenAccess), keyEquivalent: "")
        ask.target = self
        ask.toolTip = "Shows the macOS prompt. Relaunch Scribe after granting."
        menu.addItem(ask)
        menu.addItem(permissionItem(
            title: "Accessibility",
            granted: AXInspector.isTrusted,
            unknown: false,
            action: #selector(openAccessibilitySettings)))

        menu.addItem(.separator())
        let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let quit = NSMenuItem(title: "Quit Scribe", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// "Capture Area ▸" — what goes in the screenshot. The app list is built
    /// fresh each time the menu opens, from whatever is actually running, so it
    /// is short and relevant rather than a fixed guess.
    /// "Record Clicks ▸": every click, or only clicks with a chosen key held.
    func buildClickGateItem() -> NSMenuItem {
        let current = Settings.shared.clickGate
        let item = NSMenuItem(title: current == .off ? "Record Clicks: Every Click"
                                                     : "Record Clicks: \(current.keyName)",
                              action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for gate in ClickGate.allCases {
            let entry = NSMenuItem(title: gate.menuTitle,
                                   action: #selector(setClickGate(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = gate.rawValue
            entry.state = gate == current ? .on : .off
            submenu.addItem(entry)
            if gate == .off { submenu.addItem(.separator()) }
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("The app you are recording still sees the key —"))
        submenu.addItem(disabled("an Option-click on a link downloads it in a browser."))
        submenu.addItem(disabled("Holding Fn for a GIF step always records."))
        item.submenu = submenu
        return item
    }

    @objc func toggleHideBrowserChrome() {
        Settings.shared.hideBrowserChrome.toggle()
        Diag.log("hide browser chrome = \(Settings.shared.hideBrowserChrome)")
        refreshStatusItem()
    }

    @objc func setClickGate(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let gate = ClickGate(rawValue: raw) else { return }
        Settings.shared.clickGate = gate
        Diag.log("record clicks: \(gate.menuTitle)")
        refreshStatusItem()
        if isRecording, gate != .off {
            gifHUD.flash(gate.hint, on: Geo.screen(containing: NSEvent.mouseLocation), for: 2.5)
        }
    }

    func buildCaptureScopeItem() -> NSMenuItem {
        let current = Settings.shared.captureScope
        let item = NSMenuItem(title: "Capture Area: \(current.label)",
                              action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        func add(_ scope: CaptureScope, tooltip: String) {
            let entry = NSMenuItem(title: scope.label,
                                   action: #selector(setCaptureScope(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = scope.storageValue
            entry.state = (scope == current) ? .on : .off
            entry.toolTip = tooltip
            submenu.addItem(entry)
        }

        add(.clickedWindow,
            tooltip: "Crop each screenshot to the window you clicked in. Best for most guides.")
        add(.wholeScreen,
            tooltip: "The entire display, including the dock and menu bar.")

        submenu.addItem(.separator())
        submenu.addItem(disabled("Only one app"))

        let apps = Settings.commonApps()
        if apps.isEmpty {
            submenu.addItem(disabled("   (no other apps running)"))
        }
        for app in apps.prefix(12) {
            add(.app(bundleID: app.bundleID, name: app.name),
                tooltip: "Record only clicks in \(app.name), cropped to its window.")
        }

        // A scope pinned to an app that has since quit would otherwise vanish
        // from its own menu, leaving no way to see or change what is set.
        if case .app(let id, let name) = current,
           !apps.contains(where: { $0.bundleID == id }) {
            submenu.addItem(.separator())
            add(.app(bundleID: id, name: name), tooltip: "\(name) is not running right now.")
        }

        item.submenu = submenu
        return item
    }

    @objc func toggleAskForName() {
        Settings.shared.askForGuideName.toggle()
        Diag.log("ask for guide name = \(Settings.shared.askForGuideName)")
        refreshStatusItem()
    }

    /// "Export Theme ▸" — school branding on exported guides.
    func buildThemeItem() -> NSMenuItem {
        let current = Settings.shared.exportTheme
        let item = NSMenuItem(title: "Export Theme: \(current.name)",
                              action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for theme in ExportTheme.all {
            let entry = NSMenuItem(title: theme.name,
                                   action: #selector(setExportTheme(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = theme.id
            entry.state = theme.id == current.id ? .on : .off
            entry.toolTip = theme.logoResource == nil
                ? "Colours only — \(theme.accentHex), \(theme.secondaryHex), \(theme.tertiaryHex)."
                : "Logo and colours."
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(disabled("Applies to every export."))
        submenu.addItem(disabled("Highlights on screenshots stay red."))
        item.submenu = submenu
        return item
    }

    @objc func setExportTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.exportTheme = ExportTheme.with(id: id)
        Diag.log("export theme set to \(Settings.shared.exportTheme.name)")
        refreshStatusItem()
    }

    @objc func setCaptureScope(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let scope = CaptureScope.from(storage: raw)
        Settings.shared.captureScope = scope
        Diag.log("capture area set to \(scope.label)")
        refreshStatusItem()
    }

    func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Screen Recording state is only knowable once a stream has been tried —
    /// CGPreflightScreenCaptureAccess reports stale results for a rebuilt app,
    /// so the menu says "unknown" rather than guessing wrong.
    func permissionItem(title: String, granted: Bool, unknown: Bool,
                                action: Selector) -> NSMenuItem {
        let mark = unknown ? "–" : (granted ? "✓" : "✗")
        let item = NSMenuItem(title: "\(mark)  \(title)…", action: action, keyEquivalent: "")
        item.target = self
        item.toolTip = unknown
            ? "Checked when a recording starts."
            : (granted ? "Granted." : "Not granted — click to open System Settings.")
        return item
    }

    @objc func requestScreenAccess() {
        capture.requestAccess()
        openScreenRecordingSettings()
    }

    @objc func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openLog() {
        NSWorkspace.shared.open(Diag.url)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Entry point
// ─────────────────────────────────────────────────────────────────────────────

// Top-level code in main.swift runs before the main actor is formally entered,
// so building the delegate — which is @MainActor, like everything touching
// AppKit — needs the isolation stated explicitly. This *is* the main thread;
// assumeIsolated only tells the compiler so.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
