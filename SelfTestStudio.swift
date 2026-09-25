//
//  Scribe — studio editor photographs and checks
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit

extension AppDelegate {

    /// `--shot-studio` builds a synthetic three-step guide (two screenshots
    /// and one GIF step), opens the studio editor on it, photographs it in
    /// four states, and drives the parts of it a picture cannot prove: the
    /// media flip, crop through the canvas's own apply path, the canvas's
    /// coordinate round trip while cropped, and the debounced step text.
    ///
    /// Everything lands in `SCRIBE_DATA_ROOT` when that is set — run it with
    /// one, so the synthetic guide never appears in the real library.
    func shotStudio() {
        Task { @MainActor in
            await self.runStudioShots()
            NSApp.terminate(nil)
        }
    }

    private func runStudioShots() async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            Diag.log("SHOT-STUDIO: \(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        func pause(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }

        // 1. The guide.
        let synthetic = Guide()
        synthetic.title = "Set Up a Shared Class Folder"
        guard let frame = Self.syntheticFrame(),
              synthetic.append(image: frame, click: CGPoint(x: 0.30, y: 0.415),
                               target: CGRect(x: 0.22, y: 0.38, width: 0.16, height: 0.07),
                               appName: "Finder", windowTitle: "Documents",
                               elementLabel: "New Folder", verb: "Click") != nil,
              let second = synthetic.append(image: frame, click: CGPoint(x: 0.72, y: 0.66),
                                            target: nil, appName: "Finder",
                                            windowTitle: "Documents", elementLabel: "",
                                            verb: "Right-click"),
              Self.appendSyntheticGifStep(to: synthetic) != nil
        else {
            Diag.log("SHOT-STUDIO FAILED: could not build the synthetic guide")
            return
        }
        second.note = "Right-click the new folder and choose Get Info to check who can see it."
        synthetic.addMarkup(Markup(kind: .arrow, points: [CGPoint(x: 0.52, y: 0.22),
                                                          CGPoint(x: 0.39, y: 0.37)],
                                   color: .red, width: MarkupKind.arrow.defaultWidth), at: 0)
        synthetic.addRedaction(Redaction(rect: CGRect(x: 0.62, y: 0.06, width: 0.26, height: 0.05),
                                         style: .solid), at: 0)
        synthetic.save()
        guard guide.load(from: synthetic.folder), guide.count == 3 else {
            Diag.log("SHOT-STUDIO FAILED: reloading the synthetic guide gave \(guide.count) step(s)")
            return
        }
        Diag.log("SHOT-STUDIO: guide with \(guide.count) steps in \(guide.folder.path)")

        openEditor()
        guard let editor, let window = editor.window else {
            Diag.log("SHOT-STUDIO FAILED: no editor window")
            return
        }
        await pause(1.2)
        check(window.frame.width >= 1060 && window.frame.height >= 640,
              "window is \(Int(window.frame.width))x\(Int(window.frame.height))")
        let tables = Self.studioDescendants(of: window.contentView!).compactMap { $0 as? NSTableView }
        check(tables.first === editor.table && editor.table.numberOfRows == 3,
              "the step list is the first table and has 3 rows")

        // 2. Step 1 selected.
        editor.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await pause(0.5)
        dumpLayout(window)
        await studioSnapshot(window, named: "studio-list.png")
        // The same in the other appearance, so both get looked at.
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        await pause(0.5)
        await studioSnapshot(window, named: dark ? "studio-light.png" : "studio-dark.png")
        window.appearance = nil
        await pause(0.3)

        // 3. The GIF step, halfway through its trim.
        editor.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        await pause(0.3)
        let gifStep = guide.steps[2]
        check(gifStep.isGIF && !editor.trimBar.isHiddenOrHasHiddenAncestor, "the GIF step shows the transport")
        editor.scrub(toFraction: 0.5)
        await pause(0.6)
        if let clip = gifStep.gif {
            let expected = clip.trimStart + clip.length / 2
            check(abs(editor.playTime - expected) < 0.06,
                  String(format: "scrubbed to %.2f s (expected ~%.2f)", editor.playTime, expected))
        }
        await studioSnapshot(window, named: "studio-gif.png")

        // 4. Media flip, through the segmented control's own action.
        editor.mediaControl.selectedSegment = 0
        editor.mediaControl.sendAction(editor.mediaControl.action, to: editor.mediaControl.target)
        await pause(0.2)
        check(guide.steps[2].media == .screenshot, "Screenshot segment → media is screenshot")
        editor.mediaControl.selectedSegment = 1
        editor.mediaControl.sendAction(editor.mediaControl.action, to: editor.mediaControl.target)
        await pause(0.2)
        check(guide.steps[2].media == .gif, "GIF segment → media is gif")

        // 5. Step text, typed as a person would, committed by the debounce.
        let typed = "Drag the green block across to the Shared folder."
        window.makeFirstResponder(editor.noteView)
        editor.noteView.selectAll(nil)
        editor.noteView.insertText(typed, replacementRange: editor.noteView.selectedRange())
        await pause(0.1)
        check(guide.steps[2].note.isEmpty, "the note is not saved before the debounce")
        await pause(0.7)
        check(guide.steps[2].note == typed, "the debounce saved the note")
        check(editor.noteView.string == typed && window.firstResponder === editor.noteView,
              "the text view was not overwritten while being typed in")
        window.makeFirstResponder(editor.table)
        await pause(0.2)

        // 6. Crop, through the canvas and the Apply button.
        editor.modeControl.selectedSegment = 0
        editor.modeControl.sendAction(editor.modeControl.action, to: editor.modeControl.target)
        await pause(0.3)
        check(editor.canvas.mode == .crop && editor.canvas.displayCrop == nil,
              "crop mode shows the uncropped picture")
        let wanted = CGRect(x: 0.08, y: 0.16, width: 0.62, height: 0.64)
        editor.canvas.cropSelection = wanted
        await pause(0.4)
        await studioSnapshot(window, named: "studio-crop.png")
        editor.cropApplyButton.performClick(nil)
        await pause(0.4)
        let applied = guide.steps[2].crop
        check(editor.canvas.mode == .draw, "Apply leaves crop mode")
        check(applied.map { abs($0.minX - wanted.minX) + abs($0.minY - wanted.minY)
                            + abs($0.width - wanted.width) + abs($0.height - wanted.height) < 1e-6 } ?? false,
              "step.crop is the selection: \(applied.map { "\($0)" } ?? "nil")")
        check(editor.canvas.displayCrop == applied, "the canvas now shows the cropped picture")

        // 7. Coordinates while cropped: stored → view → stored, and the
        //    centre of the picture is the centre of the crop.
        let canvas = editor.canvas
        var worst: CGFloat = 0
        for p in [CGPoint(x: 0.10, y: 0.20), CGPoint(x: 0.39, y: 0.48), CGPoint(x: 0.69, y: 0.79),
                  CGPoint(x: 0.30, y: 0.415)] {
            let v = canvas.viewPoint(forStored: p)
            guard let back = canvas.storedPoint(forView: v) else { worst = 1; continue }
            worst = max(worst, abs(back.x - p.x), abs(back.y - p.y))
        }
        let frameRect = canvas.imageRect
        let viewSample = CGPoint(x: frameRect.minX + frameRect.width * 0.3,
                                 y: frameRect.minY + frameRect.height * 0.7)
        if let stored = canvas.storedPoint(forView: viewSample) {
            let again = canvas.viewPoint(forStored: stored)
            worst = max(worst, abs(again.x - viewSample.x) / max(frameRect.width, 1),
                        abs(again.y - viewSample.y) / max(frameRect.height, 1))
        }
        check(worst < 1e-6, String(format: "canvas round trip while cropped, worst error %.2e", worst))
        if let centre = canvas.storedPoint(forView: CGPoint(x: frameRect.midX, y: frameRect.midY)),
           let crop = applied {
            check(abs(centre.x - crop.midX) < 0.01 && abs(centre.y - crop.midY) < 0.01,
                  String(format: "picture centre maps to crop centre (%.3f, %.3f)", centre.x, centre.y))
        }

        // 8. Expanded.
        editor.setExpanded(true)
        await pause(0.6)
        check(editor.table.enclosingScrollView?.superview?.isHidden == true, "Expand hides the step list")
        await studioSnapshot(window, named: "studio-expanded.png")
        editor.setExpanded(false)
        await pause(0.4)
        check(editor.table.enclosingScrollView?.superview?.isHidden == false
              && (editor.table.enclosingScrollView?.frame.width ?? 0) > 150,
              "the step list comes back after Expand")

        // Put the crop back so a later look at the folder is not confusing.
        guide.setCrop(nil, at: 2)

        Diag.log(failures.isEmpty ? "SHOT-STUDIO PASSED — \(guide.folder.path)"
                                  : "SHOT-STUDIO FAILED: \(failures.joined(separator: "; "))")
    }

    private static func studioDescendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { studioDescendants(of: $0) }
    }

    /// Photographs the window with ScreenCaptureKit — the only route that
    /// shows real materials and vibrancy — and falls back to AppKit's own
    /// `cacheDisplay` when this build has no Screen Recording grant, so the
    /// layout can still be looked at.
    @discardableResult
    private func studioSnapshot(_ window: NSWindow, named: String) async -> Bool {
        let out = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent().appendingPathComponent(named)
        window.displayIfNeeded()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            if let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                let cfg = SCStreamConfiguration()
                cfg.width = Int(target.frame.width * 2)
                cfg.height = Int(target.frame.height * 2)
                cfg.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: target),
                    configuration: cfg)
                if Img.writePNG(image, to: out) {
                    Diag.log("SHOT-STUDIO: wrote \(named) \(image.width)x\(image.height) (ScreenCaptureKit)")
                    return true
                }
            } else {
                Diag.log("SHOT-STUDIO: window not in the shareable list; using cacheDisplay")
            }
        } catch {
            Diag.log("SHOT-STUDIO: ScreenCaptureKit unavailable (\(error.localizedDescription)); "
                     + "using cacheDisplay")
        }
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage, Img.writePNG(image, to: out) else {
            Diag.log("SHOT-STUDIO: could not write \(named)")
            return false
        }
        Diag.log("SHOT-STUDIO: wrote \(named) \(image.width)x\(image.height) (cacheDisplay)")
        return true
    }
}
