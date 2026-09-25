//
//  Scribe — markup canvas, guide editor, library
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
// MARK: - Markup canvas
//
// The editor's preview, with drawing on top of it. Draws the image itself
// rather than subclassing NSImageView: the in-progress stroke, the rubber band
// and the outlines around existing annotations all have to be drawn over the
// picture, and a layer-backed NSImageView does not reliably call `draw(_:)`.
//
// Every coordinate conversion goes through `imageRect` — the picture is scaled
// to fit and centred, so there are letterbox bars on one axis almost always,
// and using `bounds` puts a drawing at a plausible-looking wrong offset.
// ─────────────────────────────────────────────────────────────────────────────

enum CanvasTool: Equatable {
    case cover
    case markup(MarkupKind)

    var label: String {
        switch self {
        case .cover: return "Cover"
        case .markup(let kind): return kind.label
        }
    }

    static let all: [CanvasTool] = [
        .cover, .markup(.arrow), .markup(.line), .markup(.box),
        .markup(.ellipse), .markup(.pen), .markup(.highlighter), .markup(.text),
    ]
}

final class MarkupCanvas: NSView, NSTextFieldDelegate {

    var image: NSImage? { didSet { needsDisplay = true } }
    /// Only for outlining what is already there — the pixels themselves are
    /// rendered upstream in `GuideStep.annotated`.
    var redactions: [Redaction] = [] { didSet { needsDisplay = true } }
    var markups: [Markup] = [] { didSet { needsDisplay = true } }

    var tool: CanvasTool = .cover { didSet { window?.invalidateCursorRects(for: self) } }
    var color: MarkupColor = .red
    /// Kept apart from `color` so picking red for an arrow does not turn the
    /// next cover red, and vice versa.
    var coverColor: MarkupColor = .black
    var redactionStyle: RedactionStyle = .solid

    var onAddRedaction: ((CGRect, MarkupColor) -> Void)?
    var onAddMarkup: ((Markup) -> Void)?
    /// Normalised point; the handler removes whatever is under it.
    var onRemove: ((CGPoint) -> Void)?

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var freehand: [CGPoint] = []
    private var textField: NSTextField?
    private var textAnchor: CGPoint?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var imageRect: CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = image.size.width * scale, h = image.size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                      width: w, height: h)
    }

    /// View point → 0…1 in the image, top-left origin. The view is bottom-left
    /// origin, hence the y flip.
    private func normalize(_ point: CGPoint) -> CGPoint? {
        let frame = imageRect
        guard frame.width > 0, frame.height > 0 else { return nil }
        return CGPoint(x: ((point.x - frame.minX) / frame.width).clamped01,
                       y: (1 - (point.y - frame.minY) / frame.height).clamped01)
    }

    private func denormalize(_ point: CGPoint) -> CGPoint {
        let frame = imageRect
        return CGPoint(x: frame.minX + point.x * frame.width,
                       y: frame.minY + (1 - point.y) * frame.height)
    }

    private func denormalize(_ rect: CGRect) -> CGRect {
        let frame = imageRect
        return CGRect(x: frame.minX + rect.minX * frame.width,
                      y: frame.minY + (1 - rect.minY - rect.height) * frame.height,
                      width: rect.width * frame.width,
                      height: rect.height * frame.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let image else { return }
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)

        // Outlines so it is obvious these are objects you can click away, not
        // part of the screenshot. They are editor-only and never exported.
        let handle = NSColor(calibratedRed: 0.29, green: 0.62, blue: 1.0, alpha: 0.9)
        handle.setStroke()
        for redaction in redactions { dashed(denormalize(redaction.rect)) }
        for markup in markups where markup.kind == .text { dashed(denormalize(markup.bounds)) }

        drawInProgress()
    }

    private func dashed(_ rect: NSRect) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }

    /// A live preview of the stroke being made. Deliberately simple — it only
    /// has to communicate shape and extent; the real rendering happens in
    /// `Annotator` against the full-resolution image.
    private func drawInProgress() {
        color.nsColor.setStroke()
        color.nsColor.setFill()

        if case .markup(let kind) = tool, kind.isFreehand, freehand.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = max(kind.defaultWidth * imageRect.width * 1.4, 2)
            path.lineCapStyle = kind == .highlighter ? .butt : .round
            path.lineJoinStyle = .round
            path.move(to: denormalize(freehand[0]))
            for p in freehand.dropFirst() { path.line(to: denormalize(p)) }
            if kind == .highlighter { color.nsColor.withAlphaComponent(0.45).setStroke() }
            path.stroke()
            return
        }

        guard let a = dragStart, let b = dragCurrent else { return }
        let band = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))

        switch tool {
        case .cover:
            let fill = redactionStyle == .solid
                ? coverColor.nsColor
                : NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1)
            fill.withAlphaComponent(0.45).setFill()
            band.fill()
            NSColor(calibratedRed: 0.29, green: 0.62, blue: 1.0, alpha: 0.9).setStroke()
            let path = NSBezierPath(rect: band)
            path.lineWidth = 1.5
            path.stroke()

        case .markup(let kind):
            let path = NSBezierPath()
            path.lineWidth = 2.5
            switch kind {
            case .box:     path.appendRect(band)
            case .ellipse: path.appendOval(in: band)
            case .line, .arrow:
                path.move(to: a); path.line(to: b)
            default: return
            }
            path.stroke()
        }
    }

    // MARK: Mouse

    override func resetCursorRects() {
        super.resetCursorRects()
        guard image != nil else { return }
        if case .markup(.text) = tool {
            addCursorRect(imageRect, cursor: .iBeam)
        } else {
            addCursorRect(imageRect, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        dragStart = point
        dragCurrent = point
        freehand = normalize(point).map { [$0] } ?? []
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragCurrent = point
        if case .markup(let kind) = tool, kind.isFreehand, let n = normalize(point) {
            // Thin the stream a little; a 90-point scribble is indistinguishable
            // from a 400-point one and much cheaper to store and re-render.
            if let last = freehand.last,
               hypot(n.x - last.x, n.y - last.y) < 0.004 { return }
            freehand.append(n)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil; dragCurrent = nil; freehand = []; needsDisplay = true
        }
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        let moved = hypot(end.x - start.x, end.y - start.y)

        if case .markup(.text) = tool {
            if let anchor = normalize(start) { beginText(at: anchor, viewPoint: start) }
            return
        }

        // A click rather than a drag always means "take this away", whatever
        // tool is selected. One gesture to undo a misplaced anything.
        if moved < 4 {
            if let point = normalize(start) { onRemove?(point) }
            return
        }

        guard let a = normalize(start), let b = normalize(end) else { return }

        switch tool {
        case .cover:
            onAddRedaction?(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                   width: abs(a.x - b.x), height: abs(a.y - b.y)),
                            coverColor)

        case .markup(let kind):
            let points: [CGPoint] = kind.isFreehand ? freehand : [a, b]
            guard points.count >= (kind.isFreehand ? 2 : 2) else { return }
            onAddMarkup?(Markup(kind: kind, points: points, color: color,
                                width: kind.defaultWidth))
        }
    }

    // MARK: Text tool

    /// An inline field at the click point, so you type where the label will be
    /// rather than in a dialog somewhere else.
    private func beginText(at anchor: CGPoint, viewPoint: CGPoint) {
        commitText()
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y - 11,
                                              width: 220, height: 22))
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.placeholderString = "Label…  ↩ to place"
        field.delegate = self
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        addSubview(field)
        textField = field
        textAnchor = anchor
        window?.makeFirstResponder(field)
    }

    private func commitText() {
        guard let field = textField, let anchor = textAnchor else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        textField = nil
        textAnchor = nil
        field.removeFromSuperview()
        guard !text.isEmpty else { return }
        onAddMarkup?(Markup(kind: .text, points: [anchor], color: color,
                            width: MarkupKind.text.defaultWidth, text: text))
    }

    private func cancelText() {
        textField?.removeFromSuperview()
        textField = nil
        textAnchor = nil
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commitText(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancelText(); return true
        default: return false
        }
    }
}

extension CGFloat {
    var clamped01: CGFloat { Swift.min(Swift.max(self, 0), 1) }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared table chrome
// ─────────────────────────────────────────────────────────────────────────────

/// A row that draws its own bottom hairline.
///
/// `NSTableView.gridStyleMask` draws separators down the whole height of the
/// scroll view, including the empty space past the last row — which, with tall
/// rows, reads as a list of blank entries rather than as a finished list. Rows
/// that draw their own line stop exactly where the data does.
final class SeparatorRowView: NSTableRowView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        let line = NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1)
        line.fill()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Guide editor
//
// Recording gets the pictures and the rough words; this window is where a
// recording becomes something you would actually hand to someone. Reorder,
// delete the mis-clicks, rewrite the sentences, then export.
//
// A normal window, not a modal — Scribe is an accessory app, and modal loops
// from one of those can block behind other windows.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class EditorWindowController: NSWindowController,
                                    NSTableViewDataSource, NSTableViewDelegate,
                                    NSTextFieldDelegate, NSSplitViewDelegate,
                                    NSWindowDelegate {

    private let guide: Guide
    private let table = NSTableView()
    private let split = NSSplitView()
    private let previewImage = MarkupCanvas()
    private var redactBar = NSStackView()
    private let stylePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toolControl = NSSegmentedControl()
    private var colorButtons: [NSButton] = []
    private let highlightToggle = NSButton(checkboxWithTitle: "Auto highlight", target: nil, action: nil)
    private var heading = NSStackView()
    private var expandButton = NSButton()
    private var isExpanded = false
    private let previewCaption = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private var upButton = NSButton()
    private var downButton = NSButton()
    private var deleteButton = NSButton()
    private var didPlaceDivider = false

    /// Called when the user confirms erasing the guide. The controller owns the
    /// confirmation sheet — it is the only window a sheet can hang off — but
    /// resetting the guide is the app delegate's job.
    var onNewGuide: (() -> Void)?

    private static let noteColumn = NSUserInterfaceItemIdentifier("note")
    private static let shotColumn = NSUserInterfaceItemIdentifier("shot")
    private static let numColumn  = NSUserInterfaceItemIdentifier("num")
    private static let rowHeight: CGFloat = 96

    init(guide: Guide) {
        self.guide = guide
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Scribe — Guide Editor"
        window.minSize = NSSize(width: 900, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent()
        window.delegate = self

        NotificationCenter.default.addObserver(
            forName: Guide.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Showing the window
    //
    // Scribe is LSUIElement: no Dock icon, and ⌘-Tab skips accessory apps
    // entirely. The first version opened this window and, the moment it slipped
    // behind a browser, left no way back to it — no Dock tile to click, nothing
    // in the switcher, and the menu-bar item just re-ran `makeKeyAndOrderFront`
    // on a window that was already "open". That is the bug that reads as "the
    // editor doesn't show up".
    //
    // So the app becomes a regular, Dock-having, ⌘-Tab-able app for exactly as
    // long as this window is open, and drops back to accessory when it closes.

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        // Without this the window stays on whichever Space it was opened on,
        // and "nothing happens" when you are looking at a different one.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        placeDividerIfNeeded()
        // Otherwise the window opens with the guide title as first responder
        // and its text selected, which reads as "rename this now".
        window.makeFirstResponder(table)
    }

    func windowDidResize(_ notification: Notification) { placeDividerIfNeeded() }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app, so Scribe stops holding a Dock tile for
        // a window that is gone — but only once no window is left. The guide
        // library keeps it alive too.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
                if !visible { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        titleField.stringValue = guide.title
        titleField.font = .systemFont(ofSize: 22, weight: .semibold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none          // it is a heading, not an input box
        titleField.placeholderString = "Guide title"
        titleField.delegate = self
        titleField.tag = -1

        let titleHint = NSTextField(labelWithString: "Click the title or any step text to edit it.")
        titleHint.font = .systemFont(ofSize: 11)
        titleHint.textColor = .tertiaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.rowHeight
        // Alternating colours over 96 pt rows read as random blocks rather than
        // as a striped list. A hairline between rows does the same job quietly.
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []          // see SeparatorRowView
        table.style = .fullWidth
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.doubleAction = #selector(editSelectedText)
        table.target = self

        let num = NSTableColumn(identifier: Self.numColumn)
        num.title = "#"; num.width = 34; num.minWidth = 30; num.maxWidth = 44
        let shot = NSTableColumn(identifier: Self.shotColumn)
        shot.title = "Screenshot"; shot.width = 150; shot.minWidth = 110; shot.maxWidth = 240
        let note = NSTableColumn(identifier: Self.noteColumn)
        note.title = "Step text"; note.width = 300; note.minWidth = 200
        [num, shot, note].forEach(table.addTableColumn)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(buildPreviewPane())
        split.translatesAutoresizingMaskIntoConstraints = false

        upButton     = toolButton("chevron.up",   "Move step up",   #selector(moveStepUp))
        downButton   = toolButton("chevron.down", "Move step down", #selector(moveStepDown))
        deleteButton = toolButton("trash",        "Delete this step", #selector(deleteStep))

        let erase = NSButton(title: "New Guide", target: self, action: #selector(newGuide))
        erase.bezelStyle = .rounded
        erase.toolTip = "Start an empty guide. This one is saved and stays in the library."

        let gmail = NSButton(title: "Copy for Gmail",
                             target: self, action: #selector(copyForGmail))
        gmail.bezelStyle = .rounded
        gmail.toolTip = "Copy the whole guide, formatted, ready to paste into a Gmail message."

        let exportButton = NSPopUpButton(frame: .zero, pullsDown: true)
        exportButton.addItems(withTitles: ["Export…", "Web page (.html)",
                                           "PDF (.pdf)", "Markdown folder",
                                           "Email HTML file (.html)"])
        exportButton.item(at: 1)?.action = #selector(exportHTML)
        exportButton.item(at: 2)?.action = #selector(exportPDF)
        exportButton.item(at: 3)?.action = #selector(exportMarkdown)
        exportButton.item(at: 4)?.action = #selector(exportEmailHTML)
        exportButton.item(at: 4)?.toolTip =
            "The Gmail-safe version as a file — open it, select all, copy, paste."
        for i in 1...4 { exportButton.item(at: i)?.target = self }
        exportButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let bar = NSStackView(views: [upButton, downButton, deleteButton,
                                      statusLabel, spacer, erase, gmail, exportButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY
        bar.setCustomSpacing(16, after: deleteButton)

        heading = NSStackView(views: [titleField, titleHint])
        heading.orientation = .vertical
        heading.spacing = 2
        heading.alignment = .leading

        let root = NSView()
        [heading, split, bar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            split.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            split.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),

            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            bar.heightAnchor.constraint(equalToConstant: 26),
        ])
        return root
    }

    /// The right-hand half: a big look at the selected step. The first version
    /// left this permanently blank, because nothing was ever selected when the
    /// window opened — see `refresh`, which now always selects something.
    private func buildPreviewPane() -> NSView {
        previewImage.wantsLayer = true
        previewImage.layer?.cornerRadius = 8
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewImage.onAddRedaction = { [weak self] rect, colour in
            self?.addRedaction(rect, color: colour)
        }
        previewImage.onAddMarkup = { [weak self] markup in self?.addMarkup(markup) }
        previewImage.onRemove = { [weak self] point in self?.removeAnnotation(at: point) }

        previewCaption.font = .systemFont(ofSize: 11)
        previewCaption.textColor = .secondaryLabelColor
        previewCaption.alignment = .center
        previewCaption.lineBreakMode = .byTruncatingTail
        previewCaption.translatesAutoresizingMaskIntoConstraints = false

        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        redactBar = buildRedactionBar()
        redactBar.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.35).cgColor
        pane.layer?.cornerRadius = 8
        pane.layer?.borderWidth = 1
        pane.layer?.borderColor = NSColor.separatorColor.cgColor
        [previewImage, previewCaption, redactBar, placeholder].forEach(pane.addSubview)

        NSLayoutConstraint.activate([
            previewImage.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
            previewImage.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            previewImage.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            previewImage.bottomAnchor.constraint(equalTo: previewCaption.topAnchor, constant: -8),

            previewCaption.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            previewCaption.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            previewCaption.bottomAnchor.constraint(equalTo: redactBar.topAnchor, constant: -8),

            redactBar.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            redactBar.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -12),
            redactBar.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -12),

            placeholder.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: pane.leadingAnchor, constant: 16),
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        return pane
    }

    /// Drawing controls, kept directly under the picture they act on rather
    /// than in the window's main button bar — the drag happens up there, so the
    /// undo for it belongs there too.
    private func buildRedactionBar() -> NSStackView {
        let hint = NSTextField(labelWithString:
            "Drag to draw. Click anything you drew to remove it.")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        toolControl.segmentCount = CanvasTool.all.count
        toolControl.segmentStyle = .texturedRounded
        toolControl.trackingMode = .selectOne
        for (i, tool) in CanvasTool.all.enumerated() {
            toolControl.setLabel(tool.label, forSegment: i)
            toolControl.setWidth(0, forSegment: i)
        }
        toolControl.selectedSegment = 0
        toolControl.target = self
        toolControl.action = #selector(toolChanged)

        for style in [RedactionStyle.solid, .pixelate] {
            stylePicker.addItem(withTitle: style.label)
        }
        stylePicker.selectItem(at: 0)
        stylePicker.bezelStyle = .rounded
        stylePicker.controlSize = .small
        stylePicker.font = .systemFont(ofSize: 11)
        stylePicker.target = self
        stylePicker.action = #selector(styleChanged)
        stylePicker.toolTip = "A solid bar gives nothing away and is the safe choice. "
            + "Pixelation still shows shape and colour — fine for hiding clutter, "
            + "not for anything that matters if it is recovered."

        // Colour swatches rather than a popup: you pick a colour constantly
        // while drawing, and a menu costs two clicks every time.
        colorButtons = MarkupColor.allCases.enumerated().map { index, colour in
            let b = NSButton(title: "", target: self, action: #selector(colorChanged(_:)))
            b.tag = index
            b.bezelStyle = .shadowlessSquare
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = colour.cgColor
            b.layer?.cornerRadius = 7
            b.toolTip = colour.rawValue.capitalized
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return b
        }
        let swatches = NSStackView(views: colorButtons)
        swatches.orientation = .horizontal
        swatches.spacing = 4
        updateSwatches()

        highlightToggle.target = self
        highlightToggle.action = #selector(toggleAutoHighlight)
        highlightToggle.font = .systemFont(ofSize: 11)
        highlightToggle.toolTip = "The automatic red box or ring. Turn it off when it "
            + "landed on the wrong thing and you have drawn your own."

        func small(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.toolTip = tip
            return b
        }

        expandButton = small("Expand", #selector(toggleExpanded),
                             "Give the picture the whole window. The step list comes back "
                             + "when you switch off.")
        let undo = small("Undo", #selector(undoAnnotation), "Remove the last thing added.")
        let clear = small("Clear", #selector(clearAnnotations),
                          "Remove every cover and drawing on this step.")
        let all = small("Covers → All", #selector(applyRedactionsEverywhere),
                        "Copy this step's covers onto every other step — for a sidebar or "
                        + "header that appears in all of them. Drawings are not copied.")
        let permanent = small("Make Permanent…", #selector(flattenRedactions),
                              "Write the covers into the saved screenshots. "
                              + "Until you do, the originals on disk still show everything.")

        // Without these, expanding traps you on one step — the list you would
        // otherwise click is exactly what got collapsed.
        let previous = small("‹", #selector(previousStep), "Previous step")
        let next = small("›", #selector(nextStep), "Next step")

        let rowOne = NSStackView(views: [toolControl, previous, next, expandButton])
        rowOne.orientation = .horizontal
        rowOne.spacing = 8
        rowOne.alignment = .centerY

        let rowTwo = NSStackView(views: [swatches, stylePicker, highlightToggle])
        rowTwo.orientation = .horizontal
        rowTwo.spacing = 10
        rowTwo.alignment = .centerY

        let rowThree = NSStackView(views: [undo, clear, all, permanent])
        rowThree.orientation = .horizontal
        rowThree.spacing = 6
        rowThree.alignment = .centerY

        let stack = NSStackView(views: [hint, rowOne, rowTwo, rowThree])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        return stack
    }

    @objc private func previousStep() { step(by: -1) }
    @objc private func nextStep() { step(by: 1) }

    private func step(by delta: Int) {
        let row = table.selectedRow + delta
        guard guide.steps.indices.contains(row) else { return }
        select(row)
        updatePreview()
        updateButtons()
    }

    @objc private func toolChanged() {
        let index = min(max(toolControl.selectedSegment, 0), CanvasTool.all.count - 1)
        previewImage.tool = CanvasTool.all[index]
        stylePicker.isEnabled = previewImage.tool == .cover
        updateSwatches()
    }

    @objc private func styleChanged() {
        previewImage.redactionStyle = selectedStyle
        updateSwatches()
    }

    /// One row of swatches serves two colours: the cover's and the drawing
    /// tools'. Each keeps its own, so switching from Cover to Arrow does not
    /// turn the next arrow black.
    @objc private func colorChanged(_ sender: NSButton) {
        let colors = MarkupColor.allCases
        guard colors.indices.contains(sender.tag) else { return }
        if previewImage.tool == .cover {
            previewImage.coverColor = colors[sender.tag]
        } else {
            previewImage.color = colors[sender.tag]
        }
        updateSwatches()
    }

    /// Rings the colour the active tool will use, and greys the row out when
    /// that tool is a mosaic, which has no colour to pick.
    private func updateSwatches() {
        let isCover = previewImage.tool == .cover
        let current = isCover ? previewImage.coverColor : previewImage.color
        let usable = !(isCover && previewImage.redactionStyle == .pixelate)
        for (i, button) in colorButtons.enumerated() {
            let colour = MarkupColor.allCases[i]
            let on = colour == current
            button.layer?.borderWidth = on ? 3 : 1
            button.layer?.borderColor = NSColor.labelColor
                .withAlphaComponent(on ? 0.9 : 0.25).cgColor
            button.isEnabled = usable
            button.alphaValue = usable ? 1 : 0.35
            button.toolTip = isCover
                ? "Cover colour: \(colour.rawValue.capitalized)"
                : colour.rawValue.capitalized
        }
    }

    @objc private func toggleAutoHighlight() {
        let row = table.selectedRow
        guard guide.steps.indices.contains(row) else { return }
        guide.setShowHighlight(highlightToggle.state == .on, at: row)
        refresh()
    }

    /// Collapses the step list so the screenshot gets the whole window.
    ///
    /// The split view's minimum is normally 420 pt so the list stays usable;
    /// while expanded the delegate returns 0 instead, which is the only way
    /// `setPosition(0, …)` actually takes.
    /// For `--shot-expanded`, which cannot click the button.
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        toggleExpanded()
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        heading.isHidden = isExpanded
        expandButton.title = isExpanded ? "Show Steps" : "Expand"
        split.setPosition(isExpanded ? 0 : split.frame.width * 0.56, ofDividerAt: 0)
        split.adjustSubviews()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private var selectedStyle: RedactionStyle {
        stylePicker.indexOfSelectedItem == 1 ? .pixelate : .solid
    }

    private func addRedaction(_ rect: CGRect, color: MarkupColor) {
        let row = table.selectedRow
        guard guide.steps.indices.contains(row) else { return }
        guide.addRedaction(Redaction(rect: rect, style: selectedStyle, color: color), at: row)
        refresh()
    }

    private func addMarkup(_ markup: Markup) {
        let row = table.selectedRow
        guard guide.steps.indices.contains(row) else { return }
        guide.addMarkup(markup, at: row)
        refresh()
    }

    private func removeAnnotation(at point: CGPoint) {
        let row = table.selectedRow
        guard guide.steps.indices.contains(row) else { return }
        if guide.removeAnnotation(at: row, containing: point) { refresh() }
    }

    @objc private func undoAnnotation() {
        let row = table.selectedRow
        guard guide.steps.indices.contains(row) else { return }
        guide.undoLastAnnotation(at: row)
        refresh()
    }

    @objc private func clearAnnotations() {
        let row = table.selectedRow
        guard guide.steps.indices.contains(row) else { return }
        guide.clearAnnotations(at: row)
        refresh()
    }

    @objc private func applyRedactionsEverywhere() {
        let row = table.selectedRow
        guard guide.steps.indices.contains(row) else { return }
        let touched = guide.applyRedactionsEverywhere(from: row)
        refresh()
        report(touched == 0
               ? "Nothing to copy — draw a cover on this step first."
               : "Copied to \(touched) other step\(touched == 1 ? "" : "s").")
    }

    /// Irreversible, so it asks. Everything else in this window can be undone
    /// by drawing again; this one rewrites the only copy of the pixels.
    @objc private func flattenRedactions() {
        guard let window else { return }
        let count = guide.redactionCount
        guard count > 0 else { report("No covers to make permanent."); return }

        let alert = NSAlert()
        alert.messageText = "Write \(count) cover\(count == 1 ? "" : "s") into the screenshots?"
        // Only covers are burned in — drawings stay editable, since the reason
        // to make a cover permanent (the pixels are sensitive) does not apply
        // to an arrow.
        alert.informativeText = "Right now the covers are drawn when a guide is exported, but "
            + "the saved screenshots in \(guide.folder.lastPathComponent) still contain the "
            + "original pixels. This replaces those files. It cannot be undone."
        alert.addButton(withTitle: "Make Permanent")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let done = self.guide.flattenRedactions()
                self.refresh()
                self.report("Wrote covers into \(done) screenshot\(done == 1 ? "" : "s").")
            }
        }
    }

    private func toolButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.bezelStyle = .rounded
        b.toolTip = tip
        b.target = self
        b.action = action
        return b
    }

    /// NSSplitView ignores the arranged subviews' own constraints for the
    /// initial divider position, so it gets set once, after the window has a
    /// real width to divide.
    private func placeDividerIfNeeded() {
        guard !didPlaceDivider, split.frame.width > 100 else { return }
        didPlaceDivider = true
        split.setPosition(split.frame.width * 0.56, ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposed: CGFloat,
                   ofSubviewAt index: Int) -> CGFloat { isExpanded ? 0 : 420 }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposed: CGFloat,
                   ofSubviewAt index: Int) -> CGFloat { splitView.frame.width - 320 }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { guide.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard guide.steps.indices.contains(row) else { return nil }
        let step = guide.steps[row]
        let cell = NSView()

        switch tableColumn?.identifier {
        case Self.numColumn:
            let label = NSTextField(labelWithString: "\(row + 1)")
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            centre(label, in: cell, inset: 4)

        case Self.shotColumn:
            let iv = NSImageView()
            iv.image = step.thumbnail(number: row + 1)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 4
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                iv.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.heightAnchor.constraint(equalToConstant: Self.rowHeight - 16),
            ])

        default:
            let field = NSTextField(string: step.displayText)
            field.placeholderString = step.autoText
            field.isBordered = false
            field.drawsBackground = false
            field.font = .systemFont(ofSize: 13)
            field.textColor = step.isUserWritten ? .labelColor : .secondaryLabelColor
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 3
            field.delegate = self
            field.tag = row
            field.isEditable = true
            field.focusRingType = .none
            // Without an explicit wrapping width an NSTextField in a table cell
            // lays itself out on one endless line and simply truncates.
            field.preferredMaxLayoutWidth = max((tableColumn?.width ?? 300) - 12, 80)
            field.translatesAutoresizingMaskIntoConstraints = false

            let sub = NSTextField(labelWithString: step.contextLine)
            sub.font = .systemFont(ofSize: 10.5)
            sub.textColor = .tertiaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            sub.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(field)
            cell.addSubview(sub)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                sub.leadingAnchor.constraint(equalTo: field.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: field.trailingAnchor),
                sub.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 3),
                // The pair is centred as a block, so short and long step text
                // both sit level with their thumbnail instead of clinging to
                // the top of a 96 pt row.
                field.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: 6),
                sub.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: -8),
            ])
        }
        return cell
    }

    private func centre(_ view: NSView, in cell: NSView, inset: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            view.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -inset),
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SeparatorRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
        updateButtons()
    }

    /// Rewrites the note when a cell finishes editing. The row is carried on the
    /// field's tag, which is reassigned on every reload — so a reorder cannot
    /// land an edit on the wrong step.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === titleField || field.tag == -1 {
            guide.title = titleField.stringValue.isEmpty ? "Untitled Guide"
                                                         : titleField.stringValue
            return
        }
        let row = field.tag
        guard guide.steps.indices.contains(row) else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typing back exactly the auto sentence means "I am happy with it", not
        // "this is my hand-written text" — store nothing and stay grey.
        guide.setNote(typed == guide.steps[row].autoText ? "" : typed, at: row)
    }

    // MARK: Actions

    @objc private func moveStepUp()   { move(by: -1) }
    @objc private func moveStepDown() { move(by:  1) }

    private func move(by delta: Int) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        let landed = guide.move(from: row, by: delta)
        refresh()
        select(landed)
    }

    @objc private func deleteStep() {
        let row = table.selectedRow
        guard row >= 0 else { return }
        guide.remove(at: row)
        refresh()
        select(min(row, guide.count - 1))
    }

    /// Double-clicking a row drops straight into editing its text, which is
    /// otherwise an undiscoverable single click on an unbordered field.
    @objc private func editSelectedText() {
        let row = table.selectedRow
        guard row >= 0,
              let column = table.tableColumns.firstIndex(where: { $0.identifier == Self.noteColumn })
        else { return }
        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true),
              let field = cell.subviews.compactMap({ $0 as? NSTextField })
                              .first(where: { $0.isEditable })
        else { return }
        window?.makeFirstResponder(field)
    }

    /// No confirmation sheet: starting a new guide throws nothing away. The old
    /// one keeps its folder and shows up in the library a moment later. The
    /// previous version asked "Erase this guide?" and then did not erase it,
    /// which is a worse kind of wrong than not asking.
    @objc func newGuide() {
        onNewGuide?()
    }

    @objc private func copyForGmail() {
        guard !guide.isEmpty else { report("Nothing to copy yet."); return }
        let bytes = Export.copyForEmail(guide)
        let mb = Double(bytes) / 1_048_576
        report(String(format: "Copied %d step%@ (%.1f MB). Paste into Gmail with ⌘V.",
                      guide.count, guide.count == 1 ? "" : "s", mb))
    }

    @objc private func exportEmailHTML() {
        save(name: "\(guide.title) (email).html", type: .html) { url in
            try Export.emailHTML(self.guide)
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func exportHTML() {
        save(name: "\(guide.title).html", type: .html) { url in
            try Export.html(self.guide).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func exportMarkdown() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = guide.title
        panel.message = "Choose where to create the guide folder."
        panel.prompt = "Create"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Export.markdown(self.guide, to: url)
                self.finishExport(at: url)
            } catch {
                self.report("Markdown export failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func exportPDF() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(guide.title).pdf"
        panel.allowedContentTypes = [.pdf]

        // The layout choice belongs on the save panel rather than in a settings
        // window: it is a property of this export, and you are most likely to
        // know which one you want at the moment you are naming the file.
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        for density in Export.PageDensity.choices { picker.addItem(withTitle: density.label) }
        let saved = Settings.shared.pdfDensity
        picker.selectItem(at: Export.PageDensity.choices.firstIndex(of: saved) ?? 0)

        let caption = NSTextField(labelWithString: "Steps per page:")
        let hint = NSTextField(labelWithString:
            "A fixed count gives every step the same size — better for printing and handing out.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let row = NSStackView(views: [caption, picker])
        row.orientation = .horizontal
        row.spacing = 8
        let stack = NSStackView(views: [row, hint])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: 62)
        panel.accessoryView = stack

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let density = Export.PageDensity.choices[
                min(max(picker.indexOfSelectedItem, 0), Export.PageDensity.choices.count - 1)]
            Settings.shared.pdfDensity = density
            self.statusLabel.stringValue = "Rendering PDF (\(density.label))…"
            Export.pdf(self.guide, to: url, density: density) { error in
                if let error {
                    self.report("PDF export failed: \(error.localizedDescription)")
                } else {
                    self.finishExport(at: url)
                }
            }
        }
    }

    private func save(name: String, type: UTType, write: @escaping (URL) throws -> Void) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try write(url); self.finishExport(at: url) }
            catch { self.report("Export failed: \(error.localizedDescription)") }
        }
    }

    private func finishExport(at url: URL) {
        statusLabel.stringValue = "Exported \(url.lastPathComponent)"
        Diag.log("exported \(url.path)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func report(_ message: String) {
        statusLabel.stringValue = message
        Diag.log(message)
    }

    /// Same, for the app delegate — it owns guide-level actions but this window
    /// is where the user is looking when they take one.
    func reportStatus(_ message: String) {
        statusLabel.stringValue = message
    }

    // MARK: Refresh

    func refresh() {
        let wanted = table.selectedRow
        table.reloadData()
        // Something is always selected when there is anything to select. The
        // first version left the preview permanently blank on open because it
        // waited for the user to click a row first.
        if guide.count > 0 {
            select(guide.steps.indices.contains(wanted) ? wanted : 0)
        }
        if titleField.currentEditor() == nil { titleField.stringValue = guide.title }
        updatePreview()
        updateButtons()
        if statusLabel.stringValue.isEmpty || statusLabel.stringValue.hasSuffix("step")
            || statusLabel.stringValue.hasSuffix("steps") {
            statusLabel.stringValue = guide.isEmpty ? "" : "\(guide.count) step\(guide.count == 1 ? "" : "s")"
        }
    }

    private func select(_ row: Int) {
        guard guide.steps.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func updatePreview() {
        let row = table.selectedRow
        guard guide.steps.indices.contains(row),
              let image = guide.steps[row].annotated(number: row + 1)
        else {
            previewImage.image = nil
            previewImage.redactions = []
            previewImage.markups = []
            redactBar.isHidden = true
            previewCaption.stringValue = ""
            placeholder.stringValue = guide.isEmpty
                ? "No steps yet.\n\nPress ⌃⌥⌘R and click your way through\nwhatever you want to explain."
                : "Select a step to see it here."
            placeholder.isHidden = false
            previewImage.isHidden = true
            previewCaption.isHidden = true
            return
        }
        placeholder.isHidden = true
        previewImage.isHidden = false
        previewCaption.isHidden = false
        redactBar.isHidden = false
        previewImage.image = NSImage(cgImage: image,
                                     size: NSSize(width: image.width, height: image.height))
        let step = guide.steps[row]
        previewImage.redactions = step.redactions
        previewImage.markups = step.markups
        previewImage.window?.invalidateCursorRects(for: previewImage)
        highlightToggle.state = step.showHighlight ? .on : .off

        var extras: [String] = []
        if !step.redactions.isEmpty {
            extras.append("\(step.redactions.count) cover\(step.redactions.count == 1 ? "" : "s")")
        }
        if !step.markups.isEmpty {
            extras.append("\(step.markups.count) drawing\(step.markups.count == 1 ? "" : "s")")
        }
        previewCaption.stringValue = "Step \(row + 1) of \(guide.count)"
            + (step.contextLine.isEmpty ? "" : " · \(step.contextLine)")
            + (extras.isEmpty ? "" : " · " + extras.joined(separator: ", "))
    }

    private func updateButtons() {
        let row = table.selectedRow
        upButton.isEnabled = row > 0
        downButton.isEnabled = row >= 0 && row < guide.count - 1
        deleteButton.isEnabled = row >= 0
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Guide library
//
// Every recording has always been kept on disk under
// ~/Library/Application Support/Scribe/, but until now only the newest one was
// reachable from inside the app — everything older could be opened by hand or
// not at all. This window is the list.
// ─────────────────────────────────────────────────────────────────────────────

/// One row: read from a session folder's `guide.json` without loading its
/// screenshots. A class so the thumbnail can be cached on it after the fact.
@MainActor
final class GuideSummary {
    let folder: URL
    let title: String
    let stepCount: Int
    let modified: Date
    private let firstShot: URL?
    private var thumbCache: NSImage?

    init?(folder: URL) {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("guide.json")),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = payload["steps"] as? [[String: Any]], !steps.isEmpty
        else { return nil }

        self.folder = folder
        self.title = payload["title"] as? String ?? "Untitled Guide"
        self.stepCount = steps.count
        self.modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        self.firstShot = (steps.first?["image"] as? String)
            .map { folder.appendingPathComponent($0) }
    }

    /// The first step's screenshot, unannotated — enough to recognise which
    /// guide this is without paying to re-render a highlight.
    func thumbnail() -> NSImage? {
        if let thumbCache { return thumbCache }
        guard let firstShot, let raw = Img.readPNG(firstShot) else { return nil }
        let scale = min(190 / CGFloat(raw.width), 110 / CGFloat(raw.height), 1)
        guard let small = Img.redraw(raw, to: CGSize(
            width: (CGFloat(raw.width) * scale).rounded(),
            height: (CGFloat(raw.height) * scale).rounded()))
        else { return nil }
        let image = NSImage(cgImage: small,
                            size: NSSize(width: small.width, height: small.height))
        thumbCache = image
        return image
    }

    static func all() -> [GuideSummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Guide.root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { GuideSummary(folder: $0) }
                      .sorted { $0.modified > $1.modified }
    }
}

@MainActor
final class LibraryWindowController: NSWindowController,
                                     NSTableViewDataSource, NSTableViewDelegate,
                                     NSWindowDelegate {

    private let guide: Guide
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var summaries: [GuideSummary] = []
    private var openButton = NSButton()
    private var revealButton = NSButton()
    private var deleteButton = NSButton()

    /// Asks the app delegate to make a folder the live guide. It owns the
    /// recording state and must refuse mid-recording; this window does not.
    var onOpen: ((URL) -> Void)?
    var onNewGuide: (() -> Void)?

    private static let rowHeight: CGFloat = 92

    init(guide: Guide) {
        self.guide = guide
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Scribe — All Guides"
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent()
        window.delegate = self

        NotificationCenter.default.addObserver(
            forName: Guide.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() -> NSView {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.rowHeight
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []          // see SeparatorRowView
        table.style = .fullWidth
        table.allowsMultipleSelection = false
        table.doubleAction = #selector(openSelected)
        table.target = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("guide"))
        column.title = "Guide"
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        openButton   = bar("Open in Editor", #selector(openSelected))
        openButton.keyEquivalent = "\r"
        revealButton = bar("Show in Finder", #selector(revealSelected))
        deleteButton = bar("Delete…", #selector(deleteSelected))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        // On the left, away from the three buttons that act on the selected row —
        // this one is not about the selection.
        let newButton = bar("New Guide", #selector(newGuide))
        newButton.toolTip = "Start an empty guide. The current one stays in this list."

        let controls = NSStackView(views: [newButton, statusLabel, spacer,
                                           deleteButton, revealButton, openButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        [scroll, controls].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -10),

            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            controls.heightAnchor.constraint(equalToConstant: 26),
        ])
        return root
    }

    private func bar(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { summaries.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard summaries.indices.contains(row) else { return nil }
        let summary = summaries[row]
        let isCurrent = summary.folder == guide.folder

        let thumb = NSImageView()
        thumb.image = summary.thumbnail()
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: summary.title)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail

        let badge = NSTextField(labelWithString: "CURRENT")
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = NSColor(calibratedRed: 0.94, green: 0.16, blue: 0.35, alpha: 1)
        badge.isHidden = !isCurrent

        let heading = NSStackView(views: badge.isHidden ? [name] : [name, badge])
        heading.orientation = .horizontal
        heading.spacing = 8
        heading.alignment = .firstBaseline

        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .short
        let detail = NSTextField(labelWithString:
            "\(summary.stepCount) step\(summary.stepCount == 1 ? "" : "s") · "
            + date.string(from: summary.modified))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let text = NSStackView(views: [heading, detail])
        text.orientation = .vertical
        text.spacing = 3
        text.alignment = .leading
        text.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSView()
        cell.addSubview(thumb)
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            thumb.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 120),
            thumb.heightAnchor.constraint(equalToConstant: Self.rowHeight - 16),

            text.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 14),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SeparatorRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: Actions

    @objc private func openSelected() {
        let row = table.selectedRow
        guard summaries.indices.contains(row) else { return }
        onOpen?(summaries[row].folder)
    }

    @objc private func newGuide() {
        onNewGuide?()
    }

    @objc private func revealSelected() {
        let row = table.selectedRow
        guard summaries.indices.contains(row) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([summaries[row].folder])
    }

    @objc private func deleteSelected() {
        let row = table.selectedRow
        guard summaries.indices.contains(row), let window else { return }
        let summary = summaries[row]

        let alert = NSAlert()
        alert.messageText = "Delete “\(summary.title)”?"
        alert.informativeText = summary.folder == guide.folder
            ? "This is the guide you have open. Its \(summary.stepCount) screenshots will "
              + "be moved to the Trash and the editor will be emptied."
            : "Its \(summary.stepCount) screenshots will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.trash(summary) }
        }
    }

    /// Trash, never `removeItem`. These are the only copies of somebody's
    /// screenshots and a deletion here should be recoverable from the Finder.
    private func trash(_ summary: GuideSummary) {
        do {
            try FileManager.default.trashItem(at: summary.folder,
                                              resultingItemURL: nil)
            Diag.log("moved \(summary.folder.lastPathComponent) to the Trash")
            if summary.folder == guide.folder { guide.startNew() }
            reload()
        } catch {
            statusLabel.stringValue = "Could not delete: \(error.localizedDescription)"
            Diag.log("trash failed: \(error.localizedDescription)")
        }
    }

    // MARK: Refresh

    func reload() {
        let selectedFolder = summaries.indices.contains(table.selectedRow)
            ? summaries[table.selectedRow].folder : nil
        summaries = GuideSummary.all()
        table.reloadData()

        if let selectedFolder,
           let index = summaries.firstIndex(where: { $0.folder == selectedFolder }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if let index = summaries.firstIndex(where: { $0.folder == guide.folder }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !summaries.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        let total = summaries.reduce(0) { $0 + $1.stepCount }
        if summaries.isEmpty {
            statusLabel.stringValue = "No guides recorded yet."
        } else {
            statusLabel.stringValue = "\(summaries.count) guide"
                + "\(summaries.count == 1 ? "" : "s") · \(total) steps"
            // The live guide only reaches disk once it has a step, so an
            // in-progress recording will not be in the list yet. Say so rather
            // than letting it look missing.
            if guide.isEmpty {
                statusLabel.stringValue += " · current guide is empty"
            }
        }
        updateButtons()
    }

    private func updateButtons() {
        let has = summaries.indices.contains(table.selectedRow)
        openButton.isEnabled = has
        revealButton.isEnabled = has
        deleteButton.isEnabled = has
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        reload()
        window.makeFirstResponder(table)
    }

    func windowWillClose(_ notification: Notification) {
        // Only drop back to a menu-bar-only app if no other window is left.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
                if !visible { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}
