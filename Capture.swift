//
//  Scribe — screen capture, accessibility, prompt panels
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
// MARK: - Screen capture (needs Screen Recording permission)
//
// Why a continuous stream rather than a screenshot per click:
//
// A screenshot taken *when the click is observed* is already too late. Menus
// have closed, buttons have gone dark, the sheet has appeared. A Scribe step
// has to show the screen the reader will be looking at when they are about to
// click — the state BEFORE. So a stream runs for the whole recording at 20 fps
// and every click grabs the newest frame, which is at most 50 ms old and, more
// importantly, was captured before the click landed.
//
// One stream per display, not one that follows the pointer. Restarting a
// stream takes long enough that a click just after moving to the other monitor
// would find no frame at all, and a teacher with a projector is exactly the
// person this app is for.
// ─────────────────────────────────────────────────────────────────────────────

/// Receives frames on ScreenCaptureKit's own queue. Split out so `Capture` can
/// stay main-actor isolated: this is the only genuinely off-thread code here.
private final class DisplayStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    /// Always invoked on the main thread (see the hop below).
    var onFrame: (@MainActor (CGImage) -> Void)?

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }

        // ScreenCaptureKit also emits frames carrying no new pixels — an idle
        // screen, or one it wants to mark blank. Only `.complete` has an image
        // behind it; using the others gives you a black screenshot.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else {
            Diag.once("vtfail", "VTCreateCGImageFromCVPixelBuffer returned no image")
            return
        }
        Diag.once("frame1", "first stream frame: \(image.width)x\(image.height) px")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onFrame?(image) }
        }
    }
}

@MainActor
final class Capture: NSObject, SCStreamDelegate {

    private final class Box {
        let output = DisplayStreamOutput()
        var stream: SCStream?
        var latest: CGImage?
        var starting = false
    }

    private var boxes: [CGDirectDisplayID: Box] = [:]
    private let frameQueue = DispatchQueue(label: "com.ethantruslow.scribe.frames",
                                           qos: .userInteractive)
    private var building = false
    private var retryNotBefore = Date.distantPast
    private var askedForAccess = false

    /// Set only after ScreenCaptureKit itself refuses. Never pre-checked with
    /// CGPreflightScreenCaptureAccess — that reports stale results after a
    /// rebuild and says "denied" while capture actually works.
    private(set) var permissionDenied = false
    var onPermissionDenied: (() -> Void)?

    /// Every frame from every display, on the main actor, as it arrives. The
    /// GIF recorder listens here while a clip is running; still steps never
    /// need it — they read `frame(for:)` at click time.
    var onFrame: (@MainActor (CGDirectDisplayID, CGImage) -> Void)?

    var isRunning: Bool { !boxes.isEmpty }

    /// The newest frame for a display, or nil if that display has no stream yet.
    func frame(for displayID: CGDirectDisplayID) -> CGImage? {
        boxes[displayID]?.latest
    }

    /// Idempotent. Safe to call on a timer; it only does work when a display
    /// has appeared, disappeared, or lost its stream.
    func start() {
        guard Date() >= retryNotBefore, !building else { return }
        requestAccessOnce()
        building = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.building = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)

                // Excluding our own *application* rather than a list of window
                // IDs is what keeps the prompt box out of the next screenshot.
                // Window IDs would have to be re-collected every time a panel
                // is created; a bundle identifier never changes.
                let mine = content.applications.filter {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                Diag.once("content",
                          "SCShareableContent OK: \(content.displays.count) display(s), "
                          + "excluding \(mine.count) app entry of our own")

                let live = Set(content.displays.map(\.displayID))
                for id in self.boxes.keys where !live.contains(id) {
                    self.tearDown(id)
                    Diag.log("display \(id) went away — stream stopped")
                }
                for display in content.displays {
                    self.ensureStream(for: display, excluding: mine)
                }
                self.permissionDenied = false
            } catch {
                Diag.log("SCShareableContent FAILED: \(error) | \(error.localizedDescription)")
                if Self.isUserDeclined(error) {
                    self.permissionDenied = true
                    self.onPermissionDenied?()
                } else {
                    self.retryNotBefore = Date().addingTimeInterval(2.0)
                }
            }
        }
    }

    func stop() {
        for id in boxes.keys { tearDown(id) }
        Diag.log("all capture streams stopped")
    }

    /// Without this, ScreenCaptureKit returns -3801 in 50 ms and macOS never
    /// prompts and never adds Scribe to the Screen Recording list — there is
    /// no TCC activity in the log at all, which reads exactly like a sticky
    /// refusal and is not one. `CGRequestScreenCaptureAccess` is the call that
    /// registers the app and puts the prompt on screen. It is separate from
    /// `CGPreflightScreenCaptureAccess`, which is the one worth avoiding:
    /// preflight reports stale results after a rebuild.
    ///
    /// Called once per launch. The first call shows the prompt and returns
    /// false while it is still up, so a fresh grant only takes effect on the
    /// NEXT launch.
    func requestAccess() {
        askedForAccess = true
        let granted = CGRequestScreenCaptureAccess()
        Diag.log("CGRequestScreenCaptureAccess = \(granted)")
        if !granted {
            Diag.log("Screen Recording not granted yet. If no prompt appeared, macOS "
                     + "will not prompt for this app: add Scribe.app by hand in System "
                     + "Settings › Privacy & Security › Screen & System Audio Recording "
                     + "using the + button, switch it on, then relaunch Scribe.")
        }
    }

    private func requestAccessOnce() {
        guard !askedForAccess else { return }
        requestAccess()
    }

    private func tearDown(_ id: CGDirectDisplayID) {
        guard let box = boxes.removeValue(forKey: id) else { return }
        let s = box.stream
        box.stream = nil
        box.latest = nil
        Task { try? await s?.stopCapture() }
    }

    private func ensureStream(for display: SCDisplay, excluding mine: [SCRunningApplication]) {
        let id = display.displayID
        let box = boxes[id] ?? Box()
        boxes[id] = box
        guard box.stream == nil, !box.starting else { return }
        box.starting = true

        box.output.onFrame = { [weak self, weak box] image in
            box?.latest = image
            self?.onFrame?(id, image)
        }

        let filter = SCContentFilter(display: display,
                                     excludingApplications: mine,
                                     exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        let scale = self.backingScale(for: id)
        cfg.width  = max(Int(CGFloat(display.width) * scale), 2)
        cfg.height = max(Int(CGFloat(display.height) * scale), 2)
        cfg.showsCursor = false          // the highlight marks the spot, not the arrow
        cfg.captureResolution = .best
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // 5, not 3. The GIF recorder keeps a frame alive on its own queue while
        // it crops and encodes it, and that frame's IOSurface belongs to this
        // pool; `latest` holds another. With only three surfaces, one held by
        // the encoder and one by `latest` leaves ScreenCaptureKit a single
        // buffer to render into, and it starts dropping frames — exactly while
        // a clip is recording, which is the one time frames matter most.
        cfg.queueDepth = 5
        // 20 fps: the newest frame is then at most 50 ms stale, which is well
        // inside "before the click", and an idle screen still costs nothing
        // because ScreenCaptureKit only sends frames when pixels change.
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        // Deliberately NOT setting colorSpaceName. Pinning a P3 display to sRGB
        // makes Core Animation re-render every frame through a colour
        // conversion on the main thread.

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(box.output, type: .screen, sampleHandlerQueue: frameQueue)
        } catch {
            Diag.log("addStreamOutput FAILED for display \(id): \(error)")
            box.starting = false
            return
        }

        Task { [weak self, weak box] in
            do {
                try await s.startCapture()
                box?.stream = s
                box?.starting = false
                self?.permissionDenied = false
                Diag.log("capture stream started on display \(id) at \(cfg.width)x\(cfg.height) px")
            } catch {
                box?.starting = false
                Diag.log("startCapture FAILED on display \(id): \(error) | \(error.localizedDescription)")
                guard let self else { return }
                if Self.isUserDeclined(error) {
                    self.permissionDenied = true
                    self.onPermissionDenied?()
                } else {
                    // A display asleep or reconfiguring looks exactly like this
                    // and is transient. Only -3801 is a real refusal.
                    self.boxes[id] = nil
                    self.retryNotBefore = Date().addingTimeInterval(2.0)
                }
            }
        }
    }

    private func backingScale(for id: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens where Geo.displayID(of: screen) == id {
            return screen.backingScaleFactor
        }
        return 2
    }

    /// -3801 is ScreenCaptureKit's "the user declined TCC" — the one error no
    /// retry gets past. A stopped stream is not a denied permission.
    private static func isUserDeclined(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == SCStreamErrorDomain && ns.code == -3801
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Diag.log("stream stopped with error: \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            for (id, box) in self.boxes where box.stream === stream {
                self.boxes[id] = nil
            }
            self.retryNotBefore = Date().addingTimeInterval(1.0)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Accessibility inspection (needs Accessibility permission)
//
// This is what turns "a click at (812, 340)" into "Click “Save” in Preview".
// Everything here degrades to empty strings without the permission, and the
// app stays useful: you still get the screenshot, the ring, the app name, and
// the box you type into.
// ─────────────────────────────────────────────────────────────────────────────

struct ClickTarget {
    var label: String = ""
    var windowTitle: String = ""
    var appName: String = ""
    var bundleID: String = ""
    /// Global, top-left origin, points — Accessibility's own coordinate space.
    var frame: CGRect?
    /// The frame of the window the click landed in, same coordinate space.
    /// Nil without Accessibility, or for apps that expose no window chain.
    var windowFrame: CGRect?
}

enum AXInspector {

    /// Set once. Without it a hung app (a spinning beachball under the pointer)
    /// blocks the click handler and the whole recording stutters.
    static func configure() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Must be called at the moment of the click: a fraction of a second later
    /// the frontmost app, the focused window, and the element under the pointer
    /// have all potentially changed as a *result* of the click.
    static func inspect(at globalPoint: CGPoint) -> ClickTarget {
        var out = ClickTarget()
        out.appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        guard isTrusted else { return out }

        // AX wants top-left origin, y down; NSEvent gave us bottom-left, y up.
        let axPoint = CGPoint(x: globalPoint.x, y: Geo.primaryTop - globalPoint.y)

        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(axPoint.x), Float(axPoint.y), &element)
        guard err == .success, let element else {
            Diag.once("axmiss", "AXUIElementCopyElementAtPosition returned \(err.rawValue)")
            return out
        }

        if let pid = pid(of: element),
           let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName {
            out.appName = name
        }

        if let pid = pid(of: element),
           let app = NSRunningApplication(processIdentifier: pid) {
            out.bundleID = app.bundleIdentifier ?? ""
        }

        let (label, labelled) = bestLabel(for: element)
        out.label = label
        out.frame = frame(of: labelled ?? element)
        let (title, windowRect) = window(from: element)
        out.windowTitle = title
        out.windowFrame = windowRect
        return out
    }

    /// Walks up from the deepest element until something has a usable name.
    /// A click on a button's text layer lands on an unnamed AXStaticText whose
    /// parent is the AXButton you actually pressed, so the deepest element is
    /// often the wrong one to name *and* the wrong one to draw a box around.
    private static func bestLabel(for element: AXUIElement) -> (String, AXUIElement?) {
        var node: AXUIElement? = element
        var hops = 0
        while let current = node, hops < 5 {
            for attr in ["AXTitle", "AXDescription", "AXValue", "AXHelp",
                         "AXPlaceholderValue", "AXRoleDescription"] as [CFString] {
                if let text = string(current, attr), !text.isEmpty, text.count <= 80 {
                    // AXRoleDescription is the last resort — "button" is a poor
                    // instruction, but "Click button in Finder" still beats
                    // "Click in Finder" when nothing else is exposed.
                    if attr as String == "AXRoleDescription" && hops == 0 { break }
                    return (text, current)
                }
            }
            node = parent(of: current)
            hops += 1
        }
        return ("", nil)
    }

    /// Title *and* frame of the window the click landed in. The frame is what
    /// the "Window You Click In" capture scope crops to.
    private static func window(from element: AXUIElement) -> (String, CGRect?) {
        var node: AXUIElement? = element
        var hops = 0
        while let current = node, hops < 12 {
            if let role = string(current, "AXRole" as CFString), role == "AXWindow" {
                return (string(current, "AXTitle" as CFString) ?? "", frame(of: current))
            }
            node = parent(of: current)
            hops += 1
        }
        // Some apps do not expose the chain; ask the app element directly.
        if let pid = pid(of: element) {
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                // swiftlint:disable:next force_cast
                let win = value as! AXUIElement
                return (string(win, "AXTitle" as CFString) ?? "", frame(of: win))
            }
        }
        return ("", nil)
    }

    /// The frontmost window of a named app, for the single-app capture scope
    /// when the click itself landed somewhere without a usable chain.
    static func focusedWindowFrame(ofBundleID bundleID: String) -> CGRect? {
        guard isTrusted else { return nil }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFocusedWindow" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return frame(of: value as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        // swiftlint:enable force_cast
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXParent" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value
        else { return nil }
        if let s = value as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Prompt box
//
// Appears next to the click you just made so you can say what that click was
// for, while you still remember. Deliberately non-blocking:
//
//   • `.nonactivatingPanel` — it takes keyboard focus without activating
//     Scribe, so the app you are demonstrating keeps its window chrome and its
//     place in the window order.
//   • Ignoring it is a valid action. Keep clicking and the previous box commits
//     whatever was typed (nothing, usually) and the step keeps its rule-based
//     sentence, which you can rewrite later in the editor. The recording never
//     waits for you.
//
// Never an NSAlert. A modal from an LSUIElement app can open *behind* other
// windows while the app blocks in its modal loop, which reads as a freeze.
// ─────────────────────────────────────────────────────────────────────────────

final class PromptWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PromptBox: NSObject, NSTextFieldDelegate {

    private let panel: PromptWindow
    private let numberLabel = NSTextField(labelWithString: "")
    private let autoLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private var onCommit: ((String) -> Void)?
    private var idleTimer: Timer?

    private static let width: CGFloat = 380
    private static let height: CGFloat = 108

    var isShowing: Bool { panel.isVisible }

    override init() {
        panel = PromptWindow(
            contentRect: NSRect(x: 0, y: 0, width: PromptBox.width, height: PromptBox.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: panel.contentView!.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        panel.contentView = blur

        numberLabel.font = .systemFont(ofSize: 11, weight: .bold)
        numberLabel.textColor = NSColor(calibratedRed: 0.94, green: 0.16, blue: 0.35, alpha: 1)

        autoLabel.font = .systemFont(ofSize: 11)
        autoLabel.textColor = .secondaryLabelColor
        autoLabel.lineBreakMode = .byTruncatingTail
        autoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Describe this step…"
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        let hint = NSTextField(labelWithString: "return  save     esc  skip")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        let header = NSStackView(views: [numberLabel, autoLabel])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .firstBaseline

        let stack = NSStackView(views: [header, field, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
    }

    /// Commits the box that is already open (if any) and opens a new one.
    func present(number: Int,
                 placeholder: String,
                 near globalPoint: CGPoint,
                 avoiding target: CGRect?,
                 commit: @escaping (String) -> Void) {
        commitCurrent()

        numberLabel.stringValue = "STEP \(number)"
        autoLabel.stringValue = placeholder
        field.stringValue = ""
        field.placeholderString = placeholder
        onCommit = commit

        panel.setFrameOrigin(origin(near: globalPoint, avoiding: target))
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
        Diag.once("promptkey", "prompt box key window: \(panel.isKeyWindow)")

        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.commitCurrent() }
        }
    }

    /// Saves whatever is typed and closes. Safe to call when nothing is open.
    func commitCurrent() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard let handler = onCommit else { return }
        onCommit = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.orderOut(nil)
        handler(text)
    }

    func dismiss() {
        idleTimer?.invalidate()
        idleTimer = nil
        onCommit = nil
        panel.orderOut(nil)
    }

    /// Below and right of the click by default, flipped or nudged whenever that
    /// would put the box off the screen or on top of the thing you just
    /// clicked — the reader's eye and the next click both need that spot.
    private func origin(near point: CGPoint, avoiding target: CGRect?) -> NSPoint {
        let screen = Geo.screen(containing: point) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 18

        var x = point.x + gap
        var y = point.y - PromptBox.height - gap

        if let t = target {
            // AX frame is y-down; convert its bottom edge into NSScreen space.
            let nsBottom = Geo.primaryTop - t.maxY
            y = min(y, nsBottom - PromptBox.height - gap)
            x = max(x, t.minX)
        }

        if x + PromptBox.width > bounds.maxX { x = point.x - PromptBox.width - gap }
        if y < bounds.minY { y = point.y + gap }
        x = min(max(x, bounds.minX + 8), bounds.maxX - PromptBox.width - 8)
        y = min(max(y, bounds.minY + 8), bounds.maxY - PromptBox.height - 8)
        return NSPoint(x: x, y: y)
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitCurrent()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = ""
            commitCurrent()
            return true
        default:
            return false
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Guide name prompt
//
// Asked once, when a recording starts on an empty guide. Naming it up front is
// the difference between a library full of "Untitled Guide" and one you can
// actually find things in — and the moment you press record is the moment you
// know what you are about to demonstrate.
//
// Continuing a guide that already has steps does not ask again; that is a
// resume, not a new recording.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class GuideNamePanel: NSObject, NSTextFieldDelegate {

    private let panel: PromptWindow
    private let field = NSTextField()
    private var onDone: ((String?) -> Void)?

    /// For `--shot-nameprompt`, which has to photograph this window.
    var window: NSWindow { panel }

    private static let width: CGFloat = 430
    private static let height: CGFloat = 132

    override init() {
        panel = PromptWindow(
            contentRect: NSRect(x: 0, y: 0, width: GuideNamePanel.width,
                                height: GuideNamePanel.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: panel.contentView!.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        panel.contentView = blur

        let heading = NSTextField(labelWithString: "Name this guide")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)

        let sub = NSTextField(labelWithString:
            "It becomes the title of the exported guide, and how you find it later.")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail

        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "e.g. Adding a class to a room"
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        let hint = NSTextField(labelWithString: "return  start recording     esc  cancel")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [heading, sub, field, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
    }

    /// `done` gets the typed name, or nil if the user backed out — in which
    /// case no recording starts. Pressing return with an empty field is a
    /// deliberate "just start", and yields the suggestion.
    func ask(suggestion: String, done: @escaping (String?) -> Void) {
        onDone = done
        field.stringValue = ""
        field.placeholderString = suggestion

        // Just under the menu bar on the active screen — that is where the
        // click that opened this came from.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - GuideNamePanel.width / 2,
                                     y: visible.maxY - GuideNamePanel.height - 24))
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
        Diag.once("namekey", "guide name panel key window: \(panel.isKeyWindow)")
    }

    private func finish(_ name: String?) {
        guard let handler = onDone else { return }
        onDone = nil
        panel.orderOut(nil)
        handler(name)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(typed.isEmpty ? (field.placeholderString ?? "Untitled Guide") : typed)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(nil)
            return true
        default:
            return false
        }
    }
}
