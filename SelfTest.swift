//
//  Scribe — self-tests and window photographs
//

import Cocoa
import Carbon
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit
import CoreMedia
import VideoToolbox

extension AppDelegate {

    // MARK: Self-test
    //
    // `open Scribe.app --args --selftest` exercises everything a click does
    // except the click: start the stream, wait for a real frame, synthesise a
    // step at the centre of the main screen, annotate it, and export the HTML.
    // Every stage logs, so a failure names itself instead of showing up later
    // as an empty guide. There is no way to test the click monitor this way —
    // synthetic events are invisible to it — so that stays a manual check.

    /// `--selftest-offline` runs the same pipeline against a synthetic frame,
    /// so annotation, geometry, persistence and all three exports can be
    /// verified without Screen Recording being granted yet. When the grant
    /// lands, `--selftest` covers the one stage this cannot.
    func runOfflineSelfTest() {
        Diag.log("SELFTEST-OFFLINE: starting")
        guard let canvas = Self.syntheticFrame() else {
            Diag.log("SELFTEST-OFFLINE FAILED: could not build the test image")
            NSApp.terminate(nil); return
        }
        Diag.log("SELFTEST-OFFLINE: synthetic frame \(canvas.width)x\(canvas.height) px")

        guide.title = "Scribe Offline Self Test"
        // Two steps: one with a target box, one without, so both annotation
        // paths (rounded box and ring) are exercised.
        guard guide.append(image: canvas, click: CGPoint(x: 0.30, y: 0.42),
                           target: CGRect(x: 0.22, y: 0.38, width: 0.16, height: 0.07),
                           appName: "Finder", windowTitle: "Documents",
                           elementLabel: "New Folder", verb: "Click") != nil,
              let second = guide.append(image: canvas, click: CGPoint(x: 0.72, y: 0.66),
                                        target: nil,
                                        appName: "Finder", windowTitle: "Documents",
                                        elementLabel: "", verb: "Right-click")
        else {
            Diag.log("SELFTEST-OFFLINE FAILED: could not append steps")
            NSApp.terminate(nil); return
        }
        second.note = "Right-click the empty area and pick Get Info."

        // Step 3 exercises the "Window You Click In" crop. The synthetic frame
        // stands in for a 1600x1000 pt display; the region is a window around
        // the fake button, and the click and target are renormalised against
        // that region exactly as `handleClick` does. If the maths is wrong, the
        // box lands somewhere other than the button and it is visible at a
        // glance in annotated-03.png.
        let displaySize = CGSize(width: 1600, height: 1000)
        let region = CGRect(x: 280, y: 300, width: 700, height: 440)
        let buttonLocal = CGRect(x: 0.22 * 1600, y: 0.38 * 1000,
                                 width: 0.16 * 1600, height: 0.07 * 1000)
        let clickLocal = CGPoint(x: buttonLocal.midX, y: buttonLocal.midY)

        guard let croppedFrame = Img.crop(canvas, to: region, fullSize: displaySize) else {
            Diag.log("SELFTEST-OFFLINE FAILED: crop returned nil")
            NSApp.terminate(nil); return
        }
        Diag.log("SELFTEST-OFFLINE: cropped \(croppedFrame.width)x\(croppedFrame.height) px "
                 + "from region \(Int(region.width))x\(Int(region.height)) pt")

        let normClick = Geo.normalize(localPoint: clickLocal, in: region)
        let normTarget = Geo.normalize(localRect: buttonLocal, in: region)
        // The click must land inside its own target box, in region space.
        guard normTarget.insetBy(dx: -0.01, dy: -0.01).contains(normClick) else {
            Diag.log("SELFTEST-OFFLINE FAILED: renormalised click \(normClick) "
                     + "is outside target \(normTarget)")
            NSApp.terminate(nil); return
        }
        Diag.log(String(format: "SELFTEST-OFFLINE: region-relative click (%.3f, %.3f) "
                              + "inside target (%.3f, %.3f, %.3f, %.3f)",
                        normClick.x, normClick.y, normTarget.minX, normTarget.minY,
                        normTarget.width, normTarget.height))

        guard guide.append(image: croppedFrame, click: normClick, target: normTarget,
                           appName: "Finder", windowTitle: "Cropped Window",
                           elementLabel: "New Folder", verb: "Click") != nil
        else {
            Diag.log("SELFTEST-OFFLINE FAILED: could not append the cropped step")
            NSApp.terminate(nil); return
        }

        // Redaction: one of each style on step 1, so annotated-01.png shows both.
        let pixelated = Redaction(rect: CGRect(x: 0.20, y: 0.36, width: 0.20, height: 0.11),
                                  style: .pixelate)
        let solid = Redaction(rect: CGRect(x: 0.55, y: 0.20, width: 0.22, height: 0.09),
                              style: .solid)
        guide.addRedaction(pixelated, at: 0)
        guide.addRedaction(solid, at: 0)
        let spread = guide.applyRedactionsEverywhere(from: 0)
        Diag.log("SELFTEST-OFFLINE: \(guide.steps[0].redactions.count) cover(s) on step 1, "
                 + "copied to \(spread) other step(s); \(guide.redactionCount) in the guide")

        // One of every drawing tool on step 2, so annotated-02.png shows the lot.
        let strokes: [Markup] = [
            Markup(kind: .arrow, points: [CGPoint(x: 0.60, y: 0.20), CGPoint(x: 0.40, y: 0.42)],
                   color: .red, width: MarkupKind.arrow.defaultWidth),
            Markup(kind: .line, points: [CGPoint(x: 0.10, y: 0.75), CGPoint(x: 0.34, y: 0.75)],
                   color: .blue, width: MarkupKind.line.defaultWidth),
            Markup(kind: .box, points: [CGPoint(x: 0.62, y: 0.55), CGPoint(x: 0.86, y: 0.70)],
                   color: .green, width: MarkupKind.box.defaultWidth),
            Markup(kind: .ellipse, points: [CGPoint(x: 0.06, y: 0.20), CGPoint(x: 0.26, y: 0.36)],
                   color: .orange, width: MarkupKind.ellipse.defaultWidth),
            Markup(kind: .pen,
                   points: (0...24).map { i in
                       let t = CGFloat(i) / 24
                       return CGPoint(x: 0.40 + t * 0.22, y: 0.84 + sin(t * 8) * 0.035)
                   },
                   color: .white, width: MarkupKind.pen.defaultWidth),
            Markup(kind: .highlighter,
                   points: [CGPoint(x: 0.10, y: 0.55), CGPoint(x: 0.40, y: 0.55)],
                   color: .yellow, width: MarkupKind.highlighter.defaultWidth),
            Markup(kind: .text, points: [CGPoint(x: 0.60, y: 0.90)],
                   color: .black, width: MarkupKind.text.defaultWidth,
                   text: "Type your username here"),
        ]
        for stroke in strokes { guide.addMarkup(stroke, at: 1) }
        // Step 3 stands in for "the automatic guess was wrong" — highlight off,
        // hand-drawn box instead.
        guide.setShowHighlight(false, at: 2)
        guide.addMarkup(Markup(kind: .box,
                               points: [CGPoint(x: 0.18, y: 0.30), CGPoint(x: 0.52, y: 0.52)],
                               color: .red, width: MarkupKind.box.defaultWidth), at: 2)
        Diag.log("SELFTEST-OFFLINE: \(guide.steps[1].markups.count) drawing(s) on step 2, "
                 + "step 3 highlight=\(guide.steps[2].showHighlight) "
                 + "with \(guide.steps[2].markups.count) drawing(s)")

        for (i, step) in guide.steps.enumerated() {
            guard let image = step.annotated(number: i + 1) else {
                Diag.log("SELFTEST-OFFLINE FAILED: annotate step \(i + 1) returned nil")
                NSApp.terminate(nil); return
            }
            Diag.log("SELFTEST-OFFLINE: step \(i + 1) annotated \(image.width)x\(image.height), "
                     + "text = \(step.displayText)")
            _ = Img.writePNG(image, to: guide.folder
                .appendingPathComponent(String(format: "annotated-%02d.png", i + 1)))
        }

        let htmlURL = guide.folder.appendingPathComponent("selftest.html")
        do {
            try Export.html(guide).write(to: htmlURL, atomically: true, encoding: .utf8)
            Diag.log("SELFTEST-OFFLINE: html \(byteCount(htmlURL))")
        } catch {
            Diag.log("SELFTEST-OFFLINE FAILED: html: \(error)")
            NSApp.terminate(nil); return
        }

        let emailURL = guide.folder.appendingPathComponent("selftest-email.html")
        do {
            try Export.emailHTML(guide).write(to: emailURL, atomically: true, encoding: .utf8)
            Diag.log("SELFTEST-OFFLINE: email html \(byteCount(emailURL))")
        } catch {
            Diag.log("SELFTEST-OFFLINE FAILED: email html: \(error)")
            NSApp.terminate(nil); return
        }
        let copied = Export.copyForEmail(guide)
        let board = NSPasteboard.general.string(forType: .html)?.utf8.count ?? 0
        Diag.log("SELFTEST-OFFLINE: clipboard html \(copied) bytes written, \(board) read back")

        let mdFolder = guide.folder.appendingPathComponent("markdown", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mdFolder, withIntermediateDirectories: true)
            try Export.markdown(guide, to: mdFolder)
            Diag.log("SELFTEST-OFFLINE: markdown "
                     + "\(byteCount(mdFolder.appendingPathComponent("guide.md")))")
        } catch {
            Diag.log("SELFTEST-OFFLINE FAILED: markdown: \(error)")
            NSApp.terminate(nil); return
        }

        for density in Export.PageDensity.choices where density != .fit {
            let url = guide.folder.appendingPathComponent(
                "selftest-\(density.storageValue)-per-page.pdf")
            Export.pdf(guide, to: url, density: density) { error in
                if let error {
                    Diag.log("SELFTEST-OFFLINE FAILED: pdf \(density.label): \(error)")
                } else {
                    Diag.log("SELFTEST-OFFLINE: pdf \(density.label) \(self.byteCount(url))")
                }
            }
        }

        let pdfURL = guide.folder.appendingPathComponent("selftest.pdf")
        Export.pdf(guide, to: pdfURL) { [weak self] error in
            MainActor.assumeIsolated {
                if let error {
                    Diag.log("SELFTEST-OFFLINE FAILED: pdf: \(error.localizedDescription)")
                } else {
                    Diag.log("SELFTEST-OFFLINE: pdf \(self?.byteCount(pdfURL) ?? "?")")
                    self?.exerciseContextLine()
                    self?.exerciseUndoOrdering()
                    self?.exerciseCoverColour()
                    self?.exerciseRedactionFlattening()
                    self?.exerciseEditor()
                    self?.exerciseFileNumbering()
                    Diag.log("SELFTEST-OFFLINE PASSED — \(self?.guide.folder.path ?? "")")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
            }
        }
    }

    /// Builds the editor and forces a layout pass without showing it. Most of
    /// what can go wrong in that window — a bad constraint, a nil column, a
    /// thumbnail that fails to render — goes wrong during construction, and
    /// this catches it without stealing focus from whatever you are doing.
    /// Flatten has to actually replace the pixels in the file on disk. Drawing
    /// the cover at export time only is the failure mode worth catching: the
    /// guide would look redacted while the session folder still held the
    /// original.
    private func exerciseRedactionFlattening() {
        guard let step = guide.steps.first else { return }
        let probe = CGPoint(x: 0.65, y: 0.24)          // inside the solid cover
        guard let before = Img.readPNG(step.imageURL),
              let rawBefore = Img.sample(before, at: probe) else {
            Diag.log("SELFTEST-OFFLINE FAILED: could not sample before flatten"); return
        }

        let flattened = guide.flattenRedactions()
        guard let after = Img.readPNG(step.imageURL),
              let rawAfter = Img.sample(after, at: probe) else {
            Diag.log("SELFTEST-OFFLINE FAILED: could not sample after flatten"); return
        }

        // The solid bar is a known near-black; the synthetic backdrop is not.
        let isCovered = rawAfter.r < 60 && rawAfter.g < 60 && rawAfter.b < 60
        let changed = rawBefore != rawAfter
        let cleared = guide.redactionCount == 0
        Diag.log("SELFTEST-OFFLINE: flatten rewrote \(flattened) file(s); "
                 + "raw pixel \(rawBefore) -> \(rawAfter); "
                 + "changed=\(changed) covered=\(isCovered) listCleared=\(cleared)")
        if !(changed && isCovered && cleared) {
            Diag.log("SELFTEST-OFFLINE FAILED: flatten did not destroy the stored pixels")
        }
    }

    /// A solid cover has to render in the colour it was given and keep that
    /// colour through a save and reload. The bug this replaces: every bar came
    /// out near-black whatever swatch was picked.
    private func exerciseCoverColour() {
        let index = 2
        guard guide.steps.indices.contains(index) else { return }
        let rect = CGRect(x: 0.05, y: 0.84, width: 0.16, height: 0.09)
        guide.addRedaction(Redaction(rect: rect, style: .solid, color: .yellow), at: index)
        guide.save()

        let probe = CGPoint(x: rect.midX, y: rect.midY)
        let pixel = guide.steps[index].annotated(number: index + 1)
            .flatMap { Img.sample($0, at: probe) }
        let rendered = pixel.map { $0.r > 200 && $0.g > 170 && $0.b < 90 } ?? false

        let reloaded = Guide()
        let stored = reloaded.load(from: guide.folder)
            && reloaded.steps.indices.contains(index)
            && reloaded.steps[index].redactions.contains { $0.rect == rect && $0.color == .yellow }

        Diag.log("SELFTEST-OFFLINE: yellow cover rendered \(pixel.map { "\($0)" } ?? "nil"); "
                 + "rendered=\(rendered) survivedReload=\(stored)")
        if !(rendered && stored) {
            Diag.log("SELFTEST-OFFLINE FAILED: cover colour was not applied or not saved")
        }
    }

    /// Undo has to work across covers and drawings together. They live in two
    /// arrays, so the ordering comes from `seq` — and a bug there shows up as
    /// Undo silently removing something you added five actions ago.
    private func exerciseUndoOrdering() {
        let index = 1
        guard guide.steps.indices.contains(index) else { return }
        let step = guide.steps[index]
        let before = step.annotationCount

        guide.addRedaction(Redaction(rect: CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.06),
                                     style: .solid), at: index)
        guide.addMarkup(Markup(kind: .line,
                               points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)],
                               color: .green, width: 0.004), at: index)
        let markupWasLast = step.markups.count
        guide.undoLastAnnotation(at: index)      // should drop the line
        let afterFirst = (markups: step.markups.count, covers: step.redactions.count)
        guide.undoLastAnnotation(at: index)      // should drop the cover
        let afterSecond = step.annotationCount

        let ok = afterFirst.markups == markupWasLast - 1 && afterSecond == before
        Diag.log("SELFTEST-OFFLINE: undo ordering \(before) -> +2 -> "
                 + "\(afterFirst) -> \(afterSecond); correct=\(ok)")
        if !ok { Diag.log("SELFTEST-OFFLINE FAILED: undo popped the wrong annotation") }
    }

    /// Window titles are the one place a guide can leak its author's identity,
    /// so the rule that strips them is pinned to fixtures rather than left to a
    /// "looks right in the editor" check. Every fixture is invented; none of
    /// them is anybody's real address.
    private func exerciseContextLine() {
        struct Case {
            let app: String, window: String, label: String, note: String, expect: String
        }
        let cases: [Case] = [
            // The one that started this: the account sits before the app name,
            // so a "strip everything after the app" rule never touched it.
            Case(app: "Google Chrome",
                 window: "Inbox - someone@a-school.k12.va.us - A-School Mail "
                       + "- High memory usage - 2.2 GB - Google Chrome - Name (a-school.k12.va.us)",
                 label: "", note: "Open the inbox", expect: "Inbox - A-School Mail"),
            // Profile label: the parenthesised domain takes the name with it.
            Case(app: "Google Chrome",
                 window: "All - Google Chrome - Name (a-school.k12.va.us)",
                 label: "Room One", note: "Pick a room", expect: "All · Room One"),
            // A multi-part page name must survive intact.
            Case(app: "Google Chrome",
                 window: "Home - Rooms - Google Chrome - Name (a-school.k12.va.us)",
                 label: "", note: "", expect: "Home - Rooms"),
            // An internal id is accurate and useless.
            Case(app: "Google Chrome", window: "Home - Google Chrome",
                 label: "menuOptions", note: "Click the three dots", expect: "Home"),
            Case(app: "Google Chrome", window: "Home - Google Chrome",
                 label: "btn-primary", note: "Save it", expect: "Home"),
            // Already in the step text — do not say it twice.
            Case(app: "Finder", window: "Documents - Finder",
                 label: "Rosters", note: "Click Rosters", expect: "Documents"),
            // No note: the auto text already names the element.
            Case(app: "Finder", window: "Documents - Finder",
                 label: "New Folder", note: "", expect: "Documents"),
            // Nothing to clean.
            Case(app: "Preview", window: "Handout.pdf", label: "Zoom In",
                 note: "Zoom", expect: "Handout.pdf · Zoom In"),
            // A dotted filename is not a domain.
            Case(app: "Preview", window: "Q3 Report.docx - Preview", label: "",
                 note: "Open it", expect: "Q3 Report.docx"),
            // No window title at all.
            Case(app: "Terminal", window: "", label: "", note: "Run it", expect: ""),
        ]

        var failures = 0
        for test in cases {
            let step = GuideStep(imageURL: URL(fileURLWithPath: "/dev/null"),
                                 click: .zero, target: nil,
                                 appName: test.app, windowTitle: test.window,
                                 elementLabel: test.label, verb: "Click", note: test.note)
            let got = step.contextLine
            if got != test.expect {
                failures += 1
                Diag.log("SELFTEST-OFFLINE FAILED: context expected \(test.expect.debugDescription) "
                         + "got \(got.debugDescription)")
            }
        }
        Diag.log("SELFTEST-OFFLINE: context line \(cases.count - failures)/\(cases.count) fixtures pass")
    }

    private func exerciseEditor() {
        let controller = EditorWindowController(guide: guide)
        guard let window = controller.window, let root = window.contentView else {
            Diag.log("SELFTEST-OFFLINE: editor has no content view"); return
        }
        root.layoutSubtreeIfNeeded()
        let tables = Self.descendants(of: root).compactMap { $0 as? NSTableView }
        let rows = tables.first?.numberOfRows ?? -1
        let thumbs = guide.steps.enumerated().filter { $0.element.thumbnail(number: $0.offset + 1) != nil }.count
        Diag.log("SELFTEST-OFFLINE: editor built — \(rows) row(s), "
                 + "\(thumbs)/\(guide.count) thumbnail(s), root \(Int(root.frame.width))x\(Int(root.frame.height))")
        editor = controller
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// `--shot-editor` loads the newest session, opens the editor, and has the
    /// app photograph its own window with ScreenCaptureKit. The terminal's
    /// `screencapture` needs its own Screen Recording grant and does not have
    /// one, so this is the only way to actually look at the editor's layout
    /// rather than reason about it.
    func shotEditor(thenErase: Bool = false, expanded: Bool = false) {
        eraseAfterShot = thenErase
        expandAfterShot = expanded
        guard let folder = Guide.mostRecentFolder(), guide.load(from: folder) else {
            Diag.log("SHOT: no session with steps to load"); NSApp.terminate(nil); return
        }
        Diag.log("SHOT: loaded \(guide.count) step(s) from \(folder.lastPathComponent)")
        openEditor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let window = self?.editor?.window else {
                    Diag.log("SHOT: no editor window"); NSApp.terminate(nil); return
                }
                if self?.expandAfterShot == true { self?.editor?.setExpanded(true) }
                self?.dumpLayout(window)
                Task { await self?.capture(window: window) }
            }
        }
    }

    /// `--dump-context` runs every saved guide through the context-line rule and
    /// logs the result. Deliberately logs only the cleaned output plus a
    /// yes/no on whether anything address-shaped survived — the whole point is
    /// to stop repeating the raw titles, so the check does not repeat them
    /// either.
    func dumpContext() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Guide.root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        var leaks = 0
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            guard guide.load(from: folder) else { continue }
            Diag.log("CONTEXT: === \(guide.title) (\(guide.count) steps)")
            for (i, step) in guide.steps.enumerated() {
                let line = step.contextLine
                let dirty = line.contains("@")
                    || line.range(of: #"[A-Za-z0-9-]+\.[A-Za-z]{2,6}(\.[A-Za-z]{2,6})*"#,
                                  options: .regularExpression) != nil
                if dirty { leaks += 1 }
                Diag.log("CONTEXT:   \(i + 1). \(line)\(dirty ? "   <<< STILL DIRTY" : "")")
            }
        }
        Diag.log("CONTEXT: \(leaks) line(s) still address-shaped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    /// `--shot-pdf` builds a throwaway six-step guide and exports it at every
    /// page density, so the fixed layouts can be looked at with a *full* page
    /// of slots. The real guides on disk would do, but a synthetic one keeps
    /// somebody's screenshots out of a layout check.
    func shotPDF() {
        guide.startNew()
        guide.title = "Page Layout Check"
        guard let canvas = Self.syntheticFrame() else {
            Diag.log("SHOT-PDF FAILED: no test image"); NSApp.terminate(nil); return
        }
        let texts = [
            "Open the Rooms page from the sidebar",
            "Click the three dots in the top right",
            "Choose Edit Participants — this one has a deliberately longer line of "
                + "text so the wrapping can be checked too",
            "Switch to the Rosters tab",
            "Press Add beside each class",
            "Save and close",
        ]
        for (i, text) in texts.enumerated() {
            let step = guide.append(image: canvas,
                                    click: CGPoint(x: 0.3 + 0.08 * CGFloat(i % 4), y: 0.45),
                                    target: CGRect(x: 0.22, y: 0.38, width: 0.16, height: 0.07),
                                    appName: "Google Chrome", windowTitle: "Rooms",
                                    elementLabel: "", verb: "Click")
            step?.note = text
        }

        let out = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        var pending = Export.PageDensity.choices.count
        for density in Export.PageDensity.choices {
            let name = density == .fit ? "pdf-fit.pdf" : "pdf-\(density.storageValue)up.pdf"
            Export.pdf(guide, to: out.appendingPathComponent(name), density: density) { error in
                Diag.log("SHOT-PDF: \(name) \(error.map { "FAILED \($0)" } ?? "ok")")
                pending -= 1
                if pending == 0 {
                    Diag.log("SHOT-PDF: done; scratch guide at \(self.guide.folder.path)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// `--shot-themes` exports the same three-step guide once per theme, so the
    /// branding can be compared side by side instead of one at a time.
    func shotThemes() {
        guide.startNew()
        guide.title = "Adding a Class to a Room"
        guard let canvas = Self.syntheticFrame() else {
            Diag.log("SHOT-THEMES FAILED: no test image"); NSApp.terminate(nil); return
        }
        for text in ["Open the Rooms page", "Click Edit Participants", "Press Add"] {
            let step = guide.append(image: canvas, click: CGPoint(x: 0.3, y: 0.45),
                                    target: CGRect(x: 0.22, y: 0.38, width: 0.16, height: 0.07),
                                    appName: "Google Chrome", windowTitle: "Rooms",
                                    elementLabel: "", verb: "Click")
            step?.note = text
        }

        let out = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        let original = Settings.shared.exportTheme
        for theme in ExportTheme.all {
            Settings.shared.exportTheme = theme
            let html = out.appendingPathComponent("theme-\(theme.id).html")
            try? Export.html(guide).write(to: html, atomically: true, encoding: .utf8)
            let email = out.appendingPathComponent("theme-\(theme.id)-email.html")
            try? Export.emailHTML(guide).write(to: email, atomically: true, encoding: .utf8)
            Export.pdf(guide, to: out.appendingPathComponent("theme-\(theme.id).pdf"),
                       density: .fixed(2)) { _ in }
            Diag.log("SHOT-THEMES: wrote \(theme.id) (logo: \(theme.logo != nil))")
        }
        Settings.shared.exportTheme = original
        Diag.log("SHOT-THEMES: done; scratch guide at \(guide.folder.path)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
    }

    func shotNamePrompt() {
        namePanel.ask(suggestion: Self.suggestedName()) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { NSApp.terminate(nil); return }
                Diag.log("SHOT: name panel key=\(self.namePanel.window.isKeyWindow) "
                         + "frame=\(self.namePanel.window.frame)")
                Task { await self.capture(window: self.namePanel.window,
                                          named: "nameprompt-shot.png") }
            }
        }
    }

    func shotLibrary() {
        if let folder = Guide.mostRecentFolder() { guide.load(from: folder) }
        openLibrary()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.library?.window else {
                    Diag.log("SHOT: no library window"); NSApp.terminate(nil); return
                }
                self.dumpLayout(window)
                Task { await self.capture(window: window, named: "library-shot.png") }
            }
        }
    }

    /// The frames every view actually ended up with, which is usually enough to
    /// name a layout bug without looking at a picture at all.
    func dumpLayout(_ window: NSWindow) {
        func walk(_ view: NSView, depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            let f = view.frame
            var note = "\(type(of: view)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
            if let field = view as? NSTextField {
                note += " text=\(field.stringValue.prefix(28).debugDescription)"
            }
            if let image = view as? NSImageView {
                note += " image=\(image.image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")"
            }
            if let table = view as? NSTableView {
                note += " rows=\(table.numberOfRows) rowHeight=\(Int(table.rowHeight))"
                note += " cols=\(table.tableColumns.map { "\($0.identifier.rawValue):\(Int($0.width))" }.joined(separator: ","))"
            }
            Diag.log("SHOT  \(pad)\(note)")
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        Diag.log("SHOT: window frame \(Int(window.frame.width))x\(Int(window.frame.height))")
        if let root = window.contentView { walk(root, depth: 0) }
    }

    private func capture(window: NSWindow, named: String = "editor-shot.png") async {
        let out = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent().appendingPathComponent(named)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
            }) else {
                Diag.log("SHOT FAILED: editor window not in the shareable list")
                NSApp.terminate(nil); return
            }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(target.frame.width * 2)
            cfg.height = Int(target.frame.height * 2)
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target),
                configuration: cfg)
            _ = Img.writePNG(image, to: out)
            Diag.log("SHOT: wrote \(out.lastPathComponent) \(image.width)x\(image.height)")
        } catch {
            Diag.log("SHOT FAILED: \(error.localizedDescription)")
        }

        if eraseAfterShot {
            eraseAfterShot = false
            let before = guide.count
            startNewGuide()
            Diag.log("SHOT: erased \(before) step(s), now \(guide.count); "
                     + "folder is \(guide.folder.lastPathComponent)")
            // Re-shoot so the empty state gets looked at too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let window = self.editor?.window else {
                        NSApp.terminate(nil); return
                    }
                    Task { await self.capture(window: window, named: "editor-erased.png") }
                }
            }
            return
        }
        NSApp.terminate(nil)
    }

    private func byteCount(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
        return "\(url.lastPathComponent) (\(size ?? -1) bytes)"
    }

    /// A stand-in for a screenshot: a desktop-ish gradient with a button-shaped
    /// rectangle where the first step's target box is meant to land, so the
    /// annotation can be checked by eye rather than only by "it returned data".
    static func syntheticFrame() -> CGImage? {
        let w = 1600, h = 1000
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: space,
                                     colors: [CGColor(red: 0.16, green: 0.21, blue: 0.34, alpha: 1),
                                              CGColor(red: 0.40, green: 0.30, blue: 0.46, alpha: 1)] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero,
                                   end: CGPoint(x: CGFloat(w), y: CGFloat(h)), options: [])
        }
        // The "button" — normalised (0.22, 0.38, 0.16, 0.07), top-left origin.
        let button = Geo.drawRect(CGRect(x: 0.22, y: 0.38, width: 0.16, height: 0.07),
                                  in: CGFloat(w), CGFloat(h))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
        ctx.addPath(CGPath(roundedRect: button, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        return ctx.makeImage()
    }

    func runSelfTest() {
        Diag.log("SELFTEST: starting")
        capture.start()
        waitForFrame(attempt: 0)
    }

    private func waitForFrame(attempt: Int) {
        guard let screen = NSScreen.main else {
            Diag.log("SELFTEST FAILED: no main screen")
            NSApp.terminate(nil); return
        }
        let displayID = Geo.displayID(of: screen)

        if let frame = capture.frame(for: displayID) {
            Diag.log("SELFTEST: got frame \(frame.width)x\(frame.height) px after \(attempt) tries")
            finishSelfTest(frame: frame, screen: screen)
            return
        }
        if capture.permissionDenied {
            Diag.log("SELFTEST FAILED: Screen Recording refused (-3801). Open System "
                     + "Settings › Privacy & Security › Screen & System Audio Recording, "
                     + "add Scribe.app with the + button if it is not listed, switch it "
                     + "on, then RELAUNCH Scribe. A grant does not apply to the process "
                     + "that was running when you made it.")
            NSApp.terminate(nil); return
        }
        guard attempt < 40 else {
            Diag.log("SELFTEST FAILED: no frame after 10s. Grant Screen Recording and retry.")
            NSApp.terminate(nil); return
        }
        capture.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.waitForFrame(attempt: attempt + 1) }
        }
    }

    private func finishSelfTest(frame: CGImage, screen: NSScreen) {
        // A synthetic click in the middle of the screen, with a target box a
        // quarter of the way across it — enough to prove the box path, the
        // ring path, the badge, and the normalised geometry all render.
        let click = CGPoint(x: 0.5, y: 0.5)
        let target = CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.08)

        guard let step = guide.append(image: frame, click: click, target: target,
                                      appName: "Self Test", windowTitle: "Synthetic",
                                      elementLabel: "Example Button", verb: "Click")
        else {
            Diag.log("SELFTEST FAILED: could not write the screenshot")
            NSApp.terminate(nil); return
        }
        Diag.log("SELFTEST: wrote \(step.imageURL.lastPathComponent), autoText = \(step.autoText)")

        guard let annotated = step.annotated(number: 1) else {
            Diag.log("SELFTEST FAILED: annotation returned nil")
            NSApp.terminate(nil); return
        }
        Diag.log("SELFTEST: annotated \(annotated.width)x\(annotated.height) px")

        guide.title = "Scribe Self Test"
        let html = Export.html(guide)
        let out = guide.folder.appendingPathComponent("selftest.html")
        do {
            try html.write(to: out, atomically: true, encoding: .utf8)
            Diag.log("SELFTEST: wrote \(byteCount(out))")
        } catch {
            Diag.log("SELFTEST FAILED: html write: \(error)")
            NSApp.terminate(nil); return
        }

        Diag.log("SELFTEST PASSED — session folder \(guide.folder.path)")
        // Give the log queue a beat to flush before the process goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    /// After a step is deleted and the guide reopened, the next screenshot
    /// must get a fresh number. It used to reuse `steps.count + 1`, which with
    /// files shot-001…003 on disk and two steps left overwrote shot-003.
    func exerciseFileNumbering() {
        guard let frame = Self.syntheticFrame() else { return }
        let scratch = Guide()
        for _ in 0..<3 {
            scratch.append(image: frame, click: CGPoint(x: 0.5, y: 0.5), target: nil,
                           appName: "Finder", windowTitle: "", elementLabel: "", verb: "Click")
        }
        scratch.remove(at: 1)
        let third = scratch.folder.appendingPathComponent("shot-003.png")
        let before = try? Data(contentsOf: third)
        let reopened = Guide()
        reopened.load(from: scratch.folder)
        let added = reopened.append(image: frame, click: CGPoint(x: 0.2, y: 0.2), target: nil,
                                    appName: "Finder", windowTitle: "", elementLabel: "",
                                    verb: "Click")
        let after = try? Data(contentsOf: third)
        let name = added?.imageURL.lastPathComponent ?? "nil"
        let ok = name == "shot-004.png" && before != nil && before == after
        Diag.log("SELFTEST-OFFLINE: file numbering after delete+reopen -> \(name); "
                 + "shot-003 untouched=\(before == after)")
        if !ok { Diag.log("SELFTEST-OFFLINE FAILED: a new shot reused a live file number") }
    }

    // MARK: Shared GIF fixtures

    /// Appends a synthetic GIF step to `guide`: 40 frames at 10 fps of the
    /// synthetic screen with a block sliding across it, a pointer track that
    /// follows the block, and one click at 1.5 s on the "button". Shared by
    /// the media, recorder and studio self-tests so they all exercise the
    /// same footage.
    @discardableResult
    static func appendSyntheticGifStep(to guide: Guide) -> GuideStep? {
        guard let base = syntheticFrame() else { return nil }
        let number = guide.reserveFileNumber()
        let folderName = String(format: "gif-%03d", number)
        let clipFolder = guide.folder.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: clipFolder, withIntermediateDirectories: true)

        let w = base.width, h = base.height
        var frames: [ClipFrame] = []
        var pointer: [PointerSample] = []
        var stillFrame: CGImage?
        for i in 0..<40 {
            let t = Double(i) / 10
            guard let ctx = Img.bitmap(width: w, height: h) else { return nil }
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
            let x = 0.10 + 0.70 * CGFloat(i) / 39
            let block = Geo.drawRect(CGRect(x: x, y: 0.70, width: 0.08, height: 0.10),
                                     in: CGFloat(w), CGFloat(h))
            ctx.setFillColor(CGColor(red: 0.20, green: 0.75, blue: 0.45, alpha: 1))
            ctx.fill(block)
            guard let image = ctx.makeImage() else { return nil }
            let name = String(format: "frame-%04d.jpg", i + 1)
            guard Img.writeJPEG(image, to: clipFolder.appendingPathComponent(name)) else { return nil }
            frames.append(ClipFrame(file: name, time: t))
            if i == 14 { stillFrame = image }
            pointer.append(PointerSample(time: t, point: CGPoint(x: x + 0.04, y: 0.66)))
        }
        let click = CGPoint(x: 0.30, y: 0.415)
        let target = CGRect(x: 0.22, y: 0.38, width: 0.16, height: 0.07)
        let clicks = [ClipClick(time: 1.5, point: click, target: target,
                                label: "New Folder", verb: "Click")]
        let data = ClipData(frames: frames, pointer: pointer, clicks: clicks, duration: 4.0,
                            pixelSize: CGSize(width: w, height: h),
                            regionPoints: CGSize(width: w / 2, height: h / 2))
        guard data.write(to: clipFolder), let still = stillFrame else { return nil }
        let trim = GifClip.defaultTrim(for: data)
        return guide.appendGif(number: number, still: still, click: click, target: target,
                               appName: "Finder", windowTitle: "Animated Window",
                               elementLabel: "New Folder", verb: "Click",
                               clip: GifClip(folder: folderName, trimStart: trim.start,
                                             trimEnd: trim.end))
    }

    // MARK: Fn probe

    /// `--probe-fn`: logs every way of seeing the Fn/Globe key for 20 s, so a
    /// person can hold Fn, an arrow key and Fn-click, and the log shows which
    /// signal is trustworthy on this machine without any new permission.
    func probeFn() {
        Diag.log("PROBE-FN: starting — hold Fn, then an arrow key, then Fn+click, for 20 s")
        var last = ""
        let started = Date()
        let timer = Timer(timeInterval: 0.05, repeats: true) { t in
            MainActor.assumeIsolated {
                let ns = NSEvent.modifierFlags.contains(.function)
                let cg = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
                let key = CGEventSource.keyState(.combinedSessionState, key: 0x3F)
                let line = "ns=\(ns) cgFlags=\(cg) keyState=\(key)"
                if line != last {
                    Diag.log(String(format: "PROBE-FN %.2fs %@", Date().timeIntervalSince(started), line))
                    last = line
                }
                if Date().timeIntervalSince(started) > 20 {
                    t.invalidate()
                    Diag.log("PROBE-FN: done")
                    NSApp.terminate(nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { event in
            Diag.log("PROBE-FN click fnFlag=\(event.modifierFlags.contains(.function))")
        }
        _ = monitor
    }
}
