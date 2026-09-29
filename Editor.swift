//
//  Scribe — the studio editor (step list, canvas, inspector) and the library
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Markup canvas
//
// The editor's picture, with drawing, cropping and the spotlight on top of it.
// Draws the image itself rather than subclassing NSImageView: the in-progress
// stroke, the rubber band, the crop handles and the outlines around existing
// annotations all have to be drawn over the picture, and a layer-backed
// NSImageView does not reliably call `draw(_:)`.
//
// Every coordinate conversion goes through `imageRect` — the picture is scaled
// to fit and centred, so there are letterbox bars on one axis almost always,
// and using `bounds` puts a drawing at a plausible-looking wrong offset.
//
// And through `displayCrop`. Step geometry (covers, drawings, the spotlight,
// the crop itself) is stored against the UNCROPPED screenshot, but once a crop
// is applied the canvas shows the cropped render. So there are three spaces:
//
//   view  ⇄  shown image 0…1  ⇄  stored image 0…1
//                              stored = crop.origin + shown × crop.size
//
// `storedPoint(forView:)` and `viewPoint(forStored:)` are the only doorways.
// A conversion that skips the crop step lands every cover at a plausible
// offset that is wrong by exactly the crop — the same bug class as normalising
// against the screen instead of the captured region.
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

    var symbol: String {
        switch self {
        case .cover: return "rectangle.fill"
        case .markup(let kind):
            switch kind {
            case .arrow: return "arrow.up.right"
            case .line: return "line.diagonal"
            case .box: return "rectangle"
            case .ellipse: return "circle"
            case .pen: return "pencil.tip"
            case .highlighter: return "highlighter"
            case .text: return "textformat"
            }
        }
    }

    var tip: String {
        switch self {
        case .cover: return "Cover — drag a bar over anything private"
        case .markup(let kind):
            switch kind {
            case .arrow: return "Arrow — drag from tail to tip"
            case .line: return "Line"
            case .box: return "Box — outline an area"
            case .ellipse: return "Circle — ring an area"
            case .pen: return "Pen — draw freehand"
            case .highlighter: return "Marker — wash colour over text"
            case .text: return "Text — click where the label goes"
            }
        }
    }

    static let all: [CanvasTool] = [
        .cover, .markup(.arrow), .markup(.line), .markup(.box),
        .markup(.ellipse), .markup(.pen), .markup(.highlighter), .markup(.text),
    ]
}

/// What a drag on the canvas does. Drawing is the normal state; crop and
/// spotlight each take the canvas over until you leave them.
enum CanvasMode: Equatable {
    case draw
    /// Shows the uncropped render with the crop rectangle and its handles.
    case crop
    /// Drag an area to spotlight; drag the magnifier inset to move it.
    case spotlight
}

final class MarkupCanvas: NSView, NSTextFieldDelegate {

    static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static let outlineBlue = NSColor(calibratedRed: 0.29, green: 0.62, blue: 1.0, alpha: 0.95)

    var image: NSImage? { didSet { geometryChanged() } }
    /// The crop already applied to `image`, in stored space. nil when the
    /// picture is the whole stored screenshot — always nil in crop mode, which
    /// has to show what is outside the crop to let you move it.
    var displayCrop: CGRect? { didSet { geometryChanged() } }
    /// Only for outlining what is already there — the pixels themselves are
    /// rendered upstream in `FrameRenderer`.
    var redactions: [Redaction] = [] { didSet { needsDisplay = true } }
    var markups: [Markup] = [] { didSet { needsDisplay = true } }
    var spotlight: Spotlight? { didSet { geometryChanged() } }

    var mode: CanvasMode = .draw {
        didSet {
            guard mode != oldValue else { return }
            cancelText()
            resetGesture()
            geometryChanged()
        }
    }
    var tool: CanvasTool = .cover { didSet { window?.invalidateCursorRects(for: self) } }
    var color: MarkupColor = .red
    /// Kept apart from `color` so picking red for an arrow does not turn the
    /// next cover red, and vice versa.
    var coverColor: MarkupColor = .black
    var redactionStyle: RedactionStyle = .solid

    /// Crop mode's rectangle, in stored space (which crop mode shows 1:1).
    var cropSelection = MarkupCanvas.whole { didSet { geometryChanged() } }
    /// Pixel width ÷ height to hold the crop to, or nil for free.
    var cropAspect: CGFloat? {
        didSet {
            if let k = normalizedAspect { cropSelection = Self.fit(cropSelection, aspect: k) }
        }
    }

    var onAddRedaction: ((CGRect, MarkupColor) -> Void)?
    var onAddMarkup: ((Markup) -> Void)?
    /// Stored-space point; the handler removes whatever is under it.
    var onRemove: ((CGPoint) -> Void)?
    /// A new spotlight area, in stored space.
    var onSpotlightArea: ((CGRect) -> Void)?
    /// New magnifier centre, 0…1 against the shown (cropped) picture — the
    /// space `Spotlight.inset` is defined in.
    var onMoveMagnifier: ((CGPoint) -> Void)?

    private enum Gesture {
        case none
        case draw
        case cropNew(anchor: CGPoint)
        case cropEdit(CropHandle, from: CGPoint, original: CGRect)
        case spotlightNew
        case magnifier(offset: CGPoint)
    }

    struct CropHandle: Equatable {
        var left = false, right = false, top = false, bottom = false
        var isMove: Bool { !left && !right && !top && !bottom }
    }

    private var gesture: Gesture = .none
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var freehand: [CGPoint] = []
    private var magnifierDrag: CGRect?
    private var textField: NSTextField?
    private var textAnchor: CGPoint?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func geometryChanged() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func resetGesture() {
        gesture = .none
        dragStart = nil
        dragCurrent = nil
        freehand = []
        magnifierDrag = nil
    }

    // MARK: Coordinates

    var imageRect: CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = (image.size.width * scale).rounded(), h = (image.size.height * scale).rounded()
        return CGRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(),
                      width: w, height: h)
    }

    private var shownCrop: CGRect { displayCrop ?? Self.whole }

    /// View point → stored 0…1, top-left origin. The view is bottom-left
    /// origin, hence the y flip; the crop step is what the doc comment above
    /// is about.
    func storedPoint(forView point: CGPoint) -> CGPoint? {
        let frame = imageRect
        guard frame.width > 0, frame.height > 0 else { return nil }
        let shown = CGPoint(x: ((point.x - frame.minX) / frame.width).clamped01,
                            y: (1 - (point.y - frame.minY) / frame.height).clamped01)
        let c = shownCrop
        return CGPoint(x: c.minX + shown.x * c.width, y: c.minY + shown.y * c.height)
    }

    func viewPoint(forStored point: CGPoint) -> CGPoint {
        let frame = imageRect, c = shownCrop
        let shown = CGPoint(x: (point.x - c.minX) / max(c.width, 0.0001),
                            y: (point.y - c.minY) / max(c.height, 0.0001))
        return CGPoint(x: frame.minX + shown.x * frame.width,
                       y: frame.minY + (1 - shown.y) * frame.height)
    }

    func viewRect(forStored rect: CGRect) -> CGRect {
        let a = viewPoint(forStored: CGPoint(x: rect.minX, y: rect.minY))
        let b = viewPoint(forStored: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// How many view points one stored image-width is, for sizing live
    /// previews the way the renderer will size the real stroke.
    private var storedLongEdgeInView: CGFloat {
        let frame = imageRect, c = shownCrop
        return max(frame.width / max(c.width, 0.0001), frame.height / max(c.height, 0.0001))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let frame = imageRect

        // A soft drop shadow lifts the screenshot off the stage, so a
        // screenshot of a mostly-white window still reads as a picture.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.set()
        NSColor.black.setFill()
        frame.fill()
        NSGraphicsContext.restoreGraphicsState()

        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true,
                   hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])

        NSGraphicsContext.saveGraphicsState()
        switch mode {
        case .draw:
            NSBezierPath(rect: frame).setClip()
            drawOutlines()
            drawInProgress()
        case .spotlight:
            NSBezierPath(rect: frame).setClip()
            drawSpotlightOverlay()
        case .crop:
            drawCropOverlay()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Outlines so it is obvious these are objects you can click away, not
    /// part of the screenshot. They are editor-only and never exported.
    private func drawOutlines() {
        Self.outlineBlue.setStroke()
        for redaction in redactions { dashed(viewRect(forStored: redaction.rect)) }
        for markup in markups where markup.kind == .text { dashed(viewRect(forStored: markup.bounds)) }
    }

    private func dashed(_ rect: NSRect, width: CGFloat = 1.5) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = width
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
            path.lineWidth = max(kind.defaultWidth * storedLongEdgeInView * 1.4, 2)
            path.lineCapStyle = kind == .highlighter ? .butt : .round
            path.lineJoinStyle = .round
            path.move(to: viewPoint(forStored: freehand[0]))
            for p in freehand.dropFirst() { path.line(to: viewPoint(forStored: p)) }
            if kind == .highlighter { color.nsColor.withAlphaComponent(0.45).setStroke() }
            path.stroke()
            return
        }

        guard case .draw = gesture, let a = dragStart, let b = dragCurrent else { return }
        let band = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))

        switch tool {
        case .cover:
            let fill = redactionStyle == .solid
                ? coverColor.nsColor
                : NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1)
            fill.withAlphaComponent(0.45).setFill()
            band.fill()
            Self.outlineBlue.setStroke()
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

    private func drawSpotlightOverlay() {
        Self.outlineBlue.setStroke()
        if let spotlight {
            dashed(viewRect(forStored: spotlight.rect), width: 2)
            if let inset = magnifierDrag ?? magnifierViewRect() { dashed(inset, width: 2) }
        }
        if case .spotlightNew = gesture, let a = dragStart, let b = dragCurrent {
            let band = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                              width: abs(a.x - b.x), height: abs(a.y - b.y))
            Self.outlineBlue.withAlphaComponent(0.14).setFill()
            band.fill()
            let path = NSBezierPath(rect: band)
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    /// Everything outside the crop is dimmed rather than hidden, so you can
    /// see what you are about to throw away. Rule-of-thirds lines inside,
    /// corner and edge handles on the frame, the pixel size in a pill.
    private func drawCropOverlay() {
        let frame = imageRect
        let v = viewRect(forStored: cropSelection)

        let shade = NSBezierPath(rect: frame)
        shade.append(NSBezierPath(rect: v))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.52).setFill()
        shade.fill()

        NSColor.white.withAlphaComponent(0.35).setStroke()
        let thirds = NSBezierPath()
        thirds.lineWidth = 0.75
        for i in 1...2 {
            let x = v.minX + v.width * CGFloat(i) / 3
            let y = v.minY + v.height * CGFloat(i) / 3
            thirds.move(to: NSPoint(x: x, y: v.minY)); thirds.line(to: NSPoint(x: x, y: v.maxY))
            thirds.move(to: NSPoint(x: v.minX, y: y)); thirds.line(to: NSPoint(x: v.maxX, y: y))
        }
        thirds.stroke()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: v.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        // L-shaped corners and short bars mid-edge, like Photos and Preview.
        // They sit just outside the frame line so they never cover the
        // pixels right at the edge of what you are keeping.
        NSColor.white.setFill()
        let arm: CGFloat = min(20, v.width / 3, v.height / 3), t: CGFloat = 3
        // (corner x, corner y, arm runs right?, arm runs up?)
        let corners: [(CGFloat, CGFloat, Bool, Bool)] = [
            (v.minX, v.minY, true, true), (v.maxX, v.minY, false, true),
            (v.minX, v.maxY, true, false), (v.maxX, v.maxY, false, false),
        ]
        for (x, y, right, up) in corners {
            NSRect(x: right ? x - t : x + t - arm, y: up ? y - t : y, width: arm, height: t).fill()
            NSRect(x: right ? x - t : x, y: up ? y - t : y + t - arm, width: t, height: arm).fill()
        }
        let bar: CGFloat = min(24, v.width / 3, v.height / 3)
        NSRect(x: v.midX - bar / 2, y: v.maxY, width: bar, height: t).fill()
        NSRect(x: v.midX - bar / 2, y: v.minY - t, width: bar, height: t).fill()
        NSRect(x: v.minX - t, y: v.midY - bar / 2, width: t, height: bar).fill()
        NSRect(x: v.maxX, y: v.midY - bar / 2, width: t, height: bar).fill()

        if let size = image?.size {
            let label = "\(Int((cropSelection.width * size.width).rounded())) × "
                + "\(Int((cropSelection.height * size.height).rounded())) px"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let text = NSAttributedString(string: label, attributes: attrs)
            let ts = text.size()
            var pill = NSRect(x: v.minX + 8, y: v.maxY - ts.height - 14,
                              width: ts.width + 14, height: ts.height + 6)
            if pill.width > v.width - 12 || pill.minY < v.minY + 4 {
                pill.origin = NSPoint(x: v.minX, y: v.maxY + 6)
            }
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            text.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 3))
        }
    }

    // MARK: Spotlight geometry

    /// Where `FrameRenderer.magnify` puts the inset, as 0…1 top-left against
    /// the output picture. The same arithmetic as the renderer, repeated here
    /// so the canvas can hit-test the inset it did not draw. All of it is
    /// proportional to the output size, so a 1000 px preview and the 1800 px
    /// still agree.
    static func magnifierRect(_ spotlight: Spotlight, crop: CGRect?, outputSize: CGSize) -> CGRect? {
        guard spotlight.mode == .magnify, outputSize.width > 0, outputSize.height > 0 else { return nil }
        var area = spotlight.rect
        if let crop {
            area = CGRect(x: (area.minX - crop.minX) / crop.width,
                          y: (area.minY - crop.minY) / crop.height,
                          width: area.width / crop.width, height: area.height / crop.height)
        }
        let w = outputSize.width, h = outputSize.height
        let source = Geo.drawRect(area, in: w, h).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !source.isNull, source.width > 4, source.height > 4 else { return nil }
        let frame = FrameRenderer.magnifierFrame(source: source, spotlight: spotlight,
                                                 in: CGRect(x: 0, y: 0, width: w, height: h))
        return CGRect(x: frame.minX / w, y: 1 - frame.maxY / h,
                      width: frame.width / w, height: frame.height / h)
    }

    /// The inset in view coordinates, or nil when there is none on screen.
    func magnifierViewRect() -> CGRect? {
        guard let spotlight, let size = image?.size,
              let n = Self.magnifierRect(spotlight, crop: displayCrop, outputSize: size)
        else { return nil }
        let f = imageRect
        return CGRect(x: f.minX + n.minX * f.width, y: f.minY + (1 - n.maxY) * f.height,
                      width: n.width * f.width, height: n.height * f.height)
    }

    // MARK: Crop geometry

    enum Anchor { case min, mid, max }

    /// The crop aspect in normalised units: a 16:9 crop of a 16:10 picture is
    /// not 16:9 in 0…1 space.
    private var normalizedAspect: CGFloat? {
        guard let a = cropAspect, let s = image?.size, s.width > 0, s.height > 0 else { return nil }
        return a * s.height / s.width
    }

    /// The largest rect of aspect `k` inside `r`, centred on it.
    static func fit(_ r: CGRect, aspect k: CGFloat) -> CGRect {
        guard r.width > 0, r.height > 0, k > 0 else { return r }
        var w = r.width, h = r.height
        if w / h > k { w = h * k } else { h = w / k }
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// Forces `r` to aspect `k`, keeping the anchored edges where they are
    /// and shrinking if the result would leave the picture.
    static func constrain(_ r: CGRect, aspect k: CGFloat, driveWidth: Bool,
                          ax: Anchor, ay: Anchor) -> CGRect {
        guard r.width > 0, r.height > 0, k > 0 else { return r }
        var w = r.width, h = r.height
        if driveWidth { h = w / k } else { w = h * k }
        func room(_ a: Anchor, _ lo: CGFloat, _ hi: CGFloat, _ mid: CGFloat) -> CGFloat {
            switch a {
            case .min: return 1 - lo
            case .max: return hi
            case .mid: return 2 * min(mid, 1 - mid)
            }
        }
        let s = min(1, room(ax, r.minX, r.maxX, r.midX) / w, room(ay, r.minY, r.maxY, r.midY) / h)
        w *= s; h *= s
        func place(_ a: Anchor, _ lo: CGFloat, _ hi: CGFloat, _ mid: CGFloat, _ size: CGFloat) -> CGFloat {
            switch a {
            case .min: return lo
            case .max: return hi - size
            case .mid: return mid - size / 2
            }
        }
        return CGRect(x: place(ax, r.minX, r.maxX, r.midX, w), y: place(ay, r.minY, r.maxY, r.midY, h),
                      width: w, height: h)
    }

    private static let handleSlop: CGFloat = 9

    /// Which part of the crop frame is under `p`: an edge, a corner, the
    /// inside (move), or nil for outside (draw a new one).
    private func cropHandle(at p: CGPoint) -> CropHandle? {
        let v = viewRect(forStored: cropSelection), t = Self.handleSlop
        let withinY = p.y >= v.minY - t && p.y <= v.maxY + t
        let withinX = p.x >= v.minX - t && p.x <= v.maxX + t
        var h = CropHandle()
        if withinY {
            if abs(p.x - v.minX) <= t { h.left = true } else if abs(p.x - v.maxX) <= t { h.right = true }
        }
        if withinX {
            if abs(p.y - v.maxY) <= t { h.top = true } else if abs(p.y - v.minY) <= t { h.bottom = true }
        }
        if !h.isMove { return h }
        return v.contains(p) ? h : nil
    }

    private func editCrop(_ handle: CropHandle, from: CGPoint, original: CGRect, to p: CGPoint) {
        let f = imageRect
        guard f.width > 0, f.height > 0 else { return }
        let dx = (p.x - from.x) / f.width
        let dy = -(p.y - from.y) / f.height          // stored y runs down
        let minSize: CGFloat = 0.05
        var r = original
        if handle.isMove {
            r.origin.x = min(max(r.minX + dx, 0), 1 - r.width)
            r.origin.y = min(max(r.minY + dy, 0), 1 - r.height)
        } else {
            var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
            if handle.left { x0 = min(max(x0 + dx, 0), x1 - minSize) }
            if handle.right { x1 = max(min(x1 + dx, 1), x0 + minSize) }
            if handle.top { y0 = min(max(y0 + dy, 0), y1 - minSize) }
            if handle.bottom { y1 = max(min(y1 + dy, 1), y0 + minSize) }
            r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            if let k = normalizedAspect {
                let ax: Anchor = handle.left ? .max : handle.right ? .min : .mid
                let ay: Anchor = handle.top ? .max : handle.bottom ? .min : .mid
                r = Self.constrain(r, aspect: k, driveWidth: handle.left || handle.right, ax: ax, ay: ay)
            }
        }
        cropSelection = r
    }

    private func newCrop(from a: CGPoint, to b: CGPoint) {
        var r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard r.width > 0.01, r.height > 0.01 else { return }
        if let k = normalizedAspect {
            r = Self.constrain(r, aspect: k, driveWidth: true,
                               ax: b.x >= a.x ? .min : .max, ay: b.y >= a.y ? .min : .max)
        }
        cropSelection = r
    }

    // MARK: Cursors

    override func resetCursorRects() {
        super.resetCursorRects()
        guard image != nil else { return }
        let frame = imageRect
        switch mode {
        case .draw:
            if case .markup(.text) = tool {
                addCursorRect(frame, cursor: .iBeam)
            } else {
                addCursorRect(frame, cursor: .crosshair)
            }
        case .spotlight:
            addCursorRect(frame, cursor: .crosshair)
            if let inset = magnifierViewRect() { addCursorRect(inset, cursor: .openHand) }
        case .crop:
            addCursorRect(frame, cursor: .crosshair)
            let v = viewRect(forStored: cropSelection), t = Self.handleSlop
            addCursorRect(v.insetBy(dx: t, dy: t), cursor: .openHand)
            addCursorRect(NSRect(x: v.minX - t, y: v.minY + t, width: 2 * t, height: max(v.height - 2 * t, 0)),
                          cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: v.maxX - t, y: v.minY + t, width: 2 * t, height: max(v.height - 2 * t, 0)),
                          cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: v.minX + t, y: v.minY - t, width: max(v.width - 2 * t, 0), height: 2 * t),
                          cursor: .resizeUpDown)
            addCursorRect(NSRect(x: v.minX + t, y: v.maxY - t, width: max(v.width - 2 * t, 0), height: 2 * t),
                          cursor: .resizeUpDown)
            for (x, y) in [(v.minX, v.minY), (v.maxX, v.minY), (v.minX, v.maxY), (v.maxX, v.maxY)] {
                addCursorRect(NSRect(x: x - t, y: y - t, width: 2 * t, height: 2 * t), cursor: Self.cornerCursor)
            }
        }
    }

    private static var cornerCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .topLeft, directions: .all)
        }
        return .crosshair
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitText()
        // Clicking the picture ends typing in the inspector, which commits it —
        // and lets Space and the crop keys reach the editor again.
        if window?.firstResponder is NSText { window?.makeFirstResponder(self) }
        guard image != nil else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch mode {
        case .draw:
            guard imageRect.contains(point) else { return }
            gesture = .draw
            dragStart = point
            dragCurrent = point
            freehand = storedPoint(forView: point).map { [$0] } ?? []

        case .crop:
            if let handle = cropHandle(at: point) {
                gesture = .cropEdit(handle, from: point, original: cropSelection)
            } else if imageRect.contains(point), let anchor = storedPoint(forView: point) {
                gesture = .cropNew(anchor: anchor)
            }

        case .spotlight:
            if let inset = magnifierViewRect(), inset.insetBy(dx: -4, dy: -4).contains(point) {
                gesture = .magnifier(offset: CGPoint(x: inset.minX - point.x, y: inset.minY - point.y))
                magnifierDrag = inset
                dragStart = point
            } else if imageRect.contains(point) {
                gesture = .spotlightNew
                dragStart = point
                dragCurrent = point
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch gesture {
        case .none:
            return
        case .draw:
            dragCurrent = point
            if case .markup(let kind) = tool, kind.isFreehand, let n = storedPoint(forView: point) {
                // Thin the stream a little; a 90-point scribble is
                // indistinguishable from a 400-point one and much cheaper to
                // store and re-render.
                if let last = freehand.last,
                   hypot(n.x - last.x, n.y - last.y) < 0.004 { return }
                freehand.append(n)
            }
        case .cropNew(let anchor):
            if let b = storedPoint(forView: point) { newCrop(from: anchor, to: b) }
        case .cropEdit(let handle, let from, let original):
            editCrop(handle, from: from, original: original, to: point)
        case .spotlightNew:
            dragCurrent = point
        case .magnifier(let offset):
            guard var r = magnifierDrag else { return }
            let f = imageRect
            r.origin = CGPoint(x: min(max(point.x + offset.x, f.minX), f.maxX - r.width),
                               y: min(max(point.y + offset.y, f.minY), f.maxY - r.height))
            magnifierDrag = r
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let end = convert(event.locationInWindow, from: nil)
        let finished = gesture
        let start = dragStart
        let points = freehand
        let inset = magnifierDrag
        resetGesture()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        guard let start else { return }
        let moved = hypot(end.x - start.x, end.y - start.y)

        switch finished {
        case .draw:
            if case .markup(.text) = tool {
                if let anchor = storedPoint(forView: start) { beginText(at: anchor, viewPoint: start) }
                return
            }
            // A click rather than a drag always means "take this away",
            // whatever tool is selected. One gesture to undo a misplaced anything.
            if moved < 4 {
                if let point = storedPoint(forView: start) { onRemove?(point) }
                return
            }
            guard let a = storedPoint(forView: start), let b = storedPoint(forView: end) else { return }
            switch tool {
            case .cover:
                onAddRedaction?(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                       width: abs(a.x - b.x), height: abs(a.y - b.y)),
                                coverColor)
            case .markup(let kind):
                let stroke: [CGPoint] = kind.isFreehand ? points : [a, b]
                guard stroke.count >= 2 else { return }
                onAddMarkup?(Markup(kind: kind, points: stroke, color: color,
                                    width: kind.defaultWidth))
            }

        case .spotlightNew:
            guard moved >= 4, let a = storedPoint(forView: start),
                  let b = storedPoint(forView: end) else { return }
            onSpotlightArea?(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                    width: abs(a.x - b.x), height: abs(a.y - b.y)))

        case .magnifier:
            guard moved >= 2, let r = inset else { return }
            let f = imageRect
            guard f.width > 0, f.height > 0 else { return }
            onMoveMagnifier?(CGPoint(x: ((r.midX - f.minX) / f.width).clamped01,
                                     y: (1 - (r.midY - f.minY) / f.height).clamped01))

        default:
            break
        }
    }

    // MARK: Text tool

    /// An inline field at the click point, so you type where the label will be
    /// rather than in a dialog somewhere else.
    private func beginText(at anchor: CGPoint, viewPoint: CGPoint) {
        commitText()
        let field = NSTextField(frame: NSRect(x: min(viewPoint.x, max(bounds.width - 224, 0)),
                                              y: viewPoint.y - 11, width: 220, height: 22))
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

    func commitText() {
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
// MARK: - Trim bar
//
// The whole clip as a strip, the kept part framed between two handles, a tick
// for every click and a playhead. Handles move live (so the labels and the
// preview follow the drag) but only commit on mouse-up: `Guide.setTrim` saves
// guide.json and invalidates the preview cache, and doing that sixty times a
// second while dragging is how a trim control starts to stutter.
// ─────────────────────────────────────────────────────────────────────────────

final class TrimBar: NSView {
    var duration: Double = 1 { didSet { needsDisplay = true; onGeometryChange?() } }
    var trimStart: Double = 0 { didSet { needsDisplay = true; onGeometryChange?() } }
    var trimEnd: Double = 1 { didSet { needsDisplay = true; onGeometryChange?() } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var clickTimes: [Double] = [] { didSet { needsDisplay = true } }
    var isActive = true { didSet { needsDisplay = true } }

    /// Live, while a handle is being dragged.
    var onChange: ((Double, Double) -> Void)?
    /// Once, on mouse-up.
    var onCommit: ((Double, Double) -> Void)?
    /// Clicking or dragging on the strip between the handles.
    var onScrub: ((Double) -> Void)?
    /// The kept range moved on screen — a resize or a trim — so anything
    /// lined up with it (the scrubber above) has to follow.
    var onGeometryChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onGeometryChange?()
    }

    /// Matches `Guide.setTrim`'s floor, so the bar never shows a range the
    /// model would refuse.
    static let minimumLength = 0.3

    private enum Grab { case start, end, playhead }
    private var grab: Grab?
    private var grabOffset: CGFloat = 0
    private let handleWidth: CGFloat = 10

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var track: CGRect {
        NSRect(x: handleWidth, y: 3, width: max(bounds.width - handleWidth * 2, 1),
               height: max(bounds.height - 6, 1))
    }

    func x(for time: Double) -> CGFloat {
        let fraction = CGFloat(min(max(time / max(duration, 0.001), 0), 1))
        return track.minX + fraction * track.width
    }

    private func time(for x: CGFloat) -> Double {
        min(max(Double((x - track.minX) / track.width) * duration, 0), duration)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = track
        let accent = isActive ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: t, xRadius: 4, yRadius: 4).fill()

        let s = x(for: trimStart), e = max(x(for: trimEnd), s + 1)
        accent.withAlphaComponent(isActive ? 0.20 : 0.12).setFill()
        NSRect(x: s, y: t.minY, width: e - s, height: t.height).fill()
        accent.setFill()
        NSRect(x: s, y: t.maxY - 2.5, width: e - s, height: 2.5).fill()
        NSRect(x: s, y: t.minY, width: e - s, height: 2.5).fill()
        NSColor.black.withAlphaComponent(0.10).setFill()
        NSRect(x: t.minX, y: t.minY, width: max(s - handleWidth - t.minX, 0), height: t.height).fill()
        NSRect(x: e + handleWidth, y: t.minY, width: max(t.maxX - e - handleWidth, 0), height: t.height).fill()

        // Clicks in the same red as the highlight, so "where does it click?"
        // is answerable without playing it.
        (NSColor(cgColor: Annotator.accent) ?? .systemRed).setFill()
        for c in clickTimes {
            let cx = x(for: c)
            NSBezierPath(ovalIn: NSRect(x: cx - 3, y: t.midY - 3, width: 6, height: 6)).fill()
        }

        for (hx, leftSide) in [(s - handleWidth, true), (e, false)] {
            let handle = NSRect(x: hx, y: t.minY, width: handleWidth, height: t.height)
            // Rounded on the outside, square where it meets the kept range.
            accent.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 4, yRadius: 4).fill()
            NSRect(x: leftSide ? handle.midX : handle.minX, y: handle.minY,
                   width: handle.width / 2, height: handle.height).fill()
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSRect(x: handle.midX - 0.75, y: handle.midY - handle.height * 0.22,
                   width: 1.5, height: handle.height * 0.44).fill()
        }

        if isActive {
            let px = x(for: playhead)
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: px - 1, y: bounds.minY, width: 2, height: bounds.height),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        let p = convert(event.locationInWindow, from: nil)
        let s = x(for: trimStart), e = x(for: trimEnd)
        if p.x >= s - handleWidth - 4 && p.x <= s + 3 {
            grab = .start; grabOffset = s - p.x
        } else if p.x >= e - 3 && p.x <= e + handleWidth + 4 {
            grab = .end; grabOffset = e - p.x
        } else {
            grab = .playhead
            scrub(to: p.x)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isActive, let grab else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch grab {
        case .start:
            trimStart = min(max(time(for: p.x + grabOffset), 0), trimEnd - Self.minimumLength)
            onChange?(trimStart, trimEnd)
        case .end:
            trimEnd = max(min(time(for: p.x + grabOffset), duration), trimStart + Self.minimumLength)
            onChange?(trimStart, trimEnd)
        case .playhead:
            scrub(to: p.x)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { grab = nil }
        guard isActive, let grab, grab != .playhead else { return }
        onCommit?(trimStart, trimEnd)
    }

    private func scrub(to x: CGFloat) {
        let t = min(max(time(for: x), trimStart), trimEnd)
        playhead = t
        onScrub?(t)
    }
}

/// Holds the scrubber over exactly the kept part of the trim bar below it.
/// The scrubber covers the trimmed range and the trim bar the whole clip;
/// stacked at full width they were two timelines at two scales, with the knob
/// and the playhead visibly disagreeing about where "now" is. Sized to the
/// kept range, they are one position on one timeline.
final class ScrubberLane: NSView {
    let slider: NSSlider
    weak var trimBar: TrimBar?

    init(slider: NSSlider) {
        self.slider = slider
        super.init(frame: .zero)
        slider.translatesAutoresizingMaskIntoConstraints = true
        addSubview(slider)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }

    override func layout() {
        super.layout()
        let height: CGFloat = 20
        guard let bar = trimBar, bar.bounds.width > 1, bar.window != nil else {
            slider.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
            return
        }
        // The knob's centre travels from half a knob in from each end.
        let inset = ((slider.cell as? NSSliderCell)?.knobThickness ?? 18) / 2
        let a = convert(NSPoint(x: bar.x(for: bar.trimStart), y: 0), from: bar).x
        let b = convert(NSPoint(x: bar.x(for: bar.trimEnd), y: 0), from: bar).x
        slider.frame = NSRect(x: a - inset, y: (bounds.height - height) / 2,
                              width: max(b - a, 1) + inset * 2, height: height)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Clip player
//
// Renders preview frames off the main thread and keeps a few of them. Each
// frame is a full `FrameRenderer.frame` — covers, spotlight, pointer, markup,
// crop — at 1000 px, which is 20–60 ms of work; doing it on the main thread at
// 10 fps would leave nothing for the rest of the editor.
//
// Every edit bumps `generation`. A render that started before the edit comes
// back carrying the old number and is dropped, so a frame drawn without the
// cover you just added can never land on screen after it.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class ClipPlayer {
    static let fps = 10.0
    static let previewEdge: CGFloat = 1000
    /// ~2.5 MB a frame at 1000 px; 36 of them is under 100 MB.
    static let cacheLimit = 36
    static let maxInFlight = 3

    private(set) var spec: RenderSpec?
    private(set) var generation = 0
    private var cache: [Int: CGImage] = [:]
    private var inFlight: Set<Int> = []
    private let queue = DispatchQueue(label: "com.ethantruslow.scribe.preview",
                                      qos: .userInitiated, attributes: .concurrent)

    /// A requested frame arrived. Only frames of the current generation.
    var onFrame: ((Double, CGImage) -> Void)?

    /// New footage or new edits: forget everything rendered so far.
    func load(_ spec: RenderSpec?) {
        generation += 1
        self.spec = spec
        cache.removeAll()
        inFlight.removeAll()
    }

    static func key(_ time: Double) -> Int { Int((time * 1000).rounded()) }

    func cached(_ time: Double) -> CGImage? { cache[Self.key(time)] }

    /// Synchronous, for the frame you are looking at right now when nothing
    /// is cached yet — a blank canvas while the first frame renders reads as
    /// broken.
    func renderNow(_ time: Double) -> CGImage? {
        if let hit = cached(time) { return hit }
        guard let spec, let image = FrameRenderer.frame(spec, at: time, maxEdge: Self.previewEdge)
        else { return nil }
        store(image, at: time)
        return image
    }

    func request(_ time: Double) {
        let key = Self.key(time)
        guard let spec, cache[key] == nil, !inFlight.contains(key),
              inFlight.count < Self.maxInFlight else { return }
        inFlight.insert(key)
        let token = generation
        let edge = Self.previewEdge
        queue.async { [weak self] in
            let image = FrameRenderer.frame(spec, at: time, maxEdge: edge)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.inFlight.remove(key)
                    guard let image else { return }
                    self.store(image, at: time)
                    self.onFrame?(time, image)
                }
            }
        }
    }

    /// The next few frames after `time`, wrapping at the end of the trim.
    func prefetch(after time: Double, clip: GifClip, count: Int = 8) {
        for i in 1...count {
            var t = time + Double(i) / Self.fps
            if t > clip.trimEnd - 0.001 { t = clip.trimStart + (t - clip.trimEnd) }
            request(Self.snap(t, in: clip))
        }
    }

    /// Frame times on the 10 fps grid that starts at the trim start, so a
    /// scrub and a playback tick ask for — and cache — the same frames.
    static func snap(_ time: Double, in clip: GifClip) -> Double {
        let steps = ((time - clip.trimStart) * fps).rounded()
        return min(max(clip.trimStart + steps / fps, clip.trimStart), clip.trimEnd)
    }

    private func store(_ image: CGImage, at time: Double) {
        let key = Self.key(time)
        if cache.count >= Self.cacheLimit, cache[key] == nil,
           let far = cache.keys.max(by: { abs($0 - key) < abs($1 - key) }) {
            cache.removeValue(forKey: far)
        }
        cache[key] = image
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Studio chrome
// ─────────────────────────────────────────────────────────────────────────────

/// Top-left origin, for scroll views whose content should start at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The neutral grey the picture sits on. Drawn rather than set as a layer
/// colour, so it follows light and dark mode without being told.
///
/// Fills `bounds`, not `dirtyRect`: since macOS 14 views do not clip to their
/// bounds by default and the dirty rect can reach outside them. Filling it
/// painted the stage grey straight over the tool strip above.
final class StageView: NSView {
    static let stage = NSColor(name: "ScribeStage") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.105, alpha: 1)
            : NSColor(calibratedWhite: 0.905, alpha: 1)
    }
    override func draw(_ dirtyRect: NSRect) {
        Self.stage.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// A hairline, for the joins between the bars and panes.
final class HairlineView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// The rounded box around the step-text editor; rings in the accent colour
/// while it is being typed in, like a focused text field.
final class FieldFrameView: NSView {
    var isFocused = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        if isFocused {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            path.lineWidth = 2.5
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }
}

/// NSTextView has no placeholder of its own. The step's automatic sentence is
/// shown here in placeholder grey until you write your own.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let pad = textContainer?.lineFragmentPadding ?? 5
        let rect = NSRect(x: textContainerInset.width + pad, y: textContainerInset.height,
                          width: bounds.width - 2 * (textContainerInset.width + pad),
                          height: bounds.height - 2 * textContainerInset.height)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// The step list. Delete and Backspace remove the selected step — from here
/// only, so pressing Delete while rewriting a sentence never deletes a step.
final class StepTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

/// The little "GIF" badge on a step row: filled when the step exports as an
/// animation, outlined when it has footage but is showing its screenshot.
final class PillView: NSView {
    var text = "GIF" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var filled = true { didSet { needsDisplay = true } }
    var onAccent = false { didSet { needsDisplay = true } }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .kern: 0.4]
    }

    override var intrinsicContentSize: NSSize {
        let s = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(s.width) + 10, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: body, xRadius: 3.5, yRadius: 3.5)
        let accent = NSColor(cgColor: Annotator.accent) ?? .systemPink
        let ink: NSColor
        if filled {
            (onAccent ? NSColor.white : accent).setFill()
            path.fill()
            ink = onAccent ? .controlAccentColor : .white
        } else {
            ink = onAccent ? .white : .secondaryLabelColor
            ink.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        var attrs = attributes
        attrs[.foregroundColor] = ink
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2,
                                            y: (bounds.height - s.height) / 2 + 0.5),
                                withAttributes: attrs)
    }
}

/// One colour choice. Drawn, not an NSButton with a layer colour, so the ring
/// follows the appearance and a disabled swatch can simply fade.
final class SwatchView: NSView {
    let swatch: MarkupColor
    var isChosen = false { didSet { needsDisplay = true } }
    var isUsable = true { didSet { needsDisplay = true } }
    var onPick: ((MarkupColor) -> Void)?

    init(_ swatch: MarkupColor) {
        self.swatch = swatch
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isUsable ? 1 : 0.3
        let dot = bounds.insetBy(dx: 4, dy: 4)
        swatch.nsColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: dot).fill()
        // A faint rim in the text colour, or the white swatch vanishes on a
        // light bar and the black one on a dark bar.
        NSColor.labelColor.withAlphaComponent(0.35 * alpha).setStroke()
        let rim = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25))
        rim.lineWidth = 0.5
        rim.stroke()
        if isChosen && isUsable {
            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isUsable else { return }
        onPick?(swatch)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Step row
// ─────────────────────────────────────────────────────────────────────────────

final class StepCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("StepCell")

    private let number = NSTextField(labelWithString: "")
    private let thumb = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let context = NSTextField(labelWithString: "")
    private let pill = PillView()
    private var isUserWritten = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        number.alignment = .right
        number.translatesAutoresizingMaskIntoConstraints = false

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false

        title.font = .systemFont(ofSize: 12)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        context.font = .systemFont(ofSize: 10.5)
        context.lineBreakMode = .byTruncatingTail
        context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let meta = NSStackView(views: [pill, context])
        meta.orientation = .horizontal
        meta.spacing = 5
        meta.alignment = .centerY

        let text = NSStackView(views: [title, meta])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        [number, thumb, text].forEach(addSubview)
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            number.widthAnchor.constraint(equalToConstant: 18),
            number.centerYAnchor.constraint(equalTo: centerYAnchor),

            thumb.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 72),
            thumb.heightAnchor.constraint(equalToConstant: 45),

            text.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 9),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ step: GuideStep, row: Int) {
        number.stringValue = "\(row + 1)"
        thumb.image = step.thumbnail(number: row + 1)
        title.stringValue = step.displayText
        isUserWritten = step.isUserWritten
        context.stringValue = step.contextLine
        context.isHidden = step.contextLine.isEmpty
        pill.isHidden = !step.hasFootage
        pill.filled = step.isGIF
        pill.toolTip = step.isGIF ? "Exports as an animated GIF"
                                  : "Has GIF footage; exporting the screenshot"
        applyColours()
    }

    /// The title wraps, and a wrapping label only wraps at a width it has
    /// been told — without this it lays out on one endless line.
    override func layout() {
        let available = bounds.width - (18 + 6 + 72 + 9 + 4)
        if available > 20, abs(title.preferredMaxLayoutWidth - available) > 0.5 {
            title.preferredMaxLayoutWidth = available
        }
        super.layout()
    }

    /// Selected rows in a focused list are white-on-accent; the system
    /// secondary colours do not follow into a hand-built cell by themselves.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColours() }
    }

    private func applyColours() {
        let emphasized = backgroundStyle == .emphasized
        number.textColor = emphasized ? .white : .secondaryLabelColor
        title.textColor = emphasized ? .white : (isUserWritten ? .labelColor : .secondaryLabelColor)
        context.textColor = emphasized ? NSColor.white.withAlphaComponent(0.8) : .tertiaryLabelColor
        pill.onAccent = emphasized
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.black.withAlphaComponent(emphasized ? 0.25 : 0.12).cgColor
    }
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
    /// Horizontal inset for the line, so it lines up with an inset-style
    /// table's rounded selection. The library keeps 0: edge to edge.
    var lineInset: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        let line = NSRect(x: lineInset, y: bounds.maxY - 1,
                          width: max(bounds.width - lineInset * 2, 0), height: 1)
        line.fill()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Editor window
//
// NSWindow itself answers `undo:` — it forwards to its undo manager, which is
// the one every text view in the window types into. So Edit ▸ Undo never gets
// past the window to reach the controller, and ⌘Z after drawing an arrow did
// nothing. This window keeps text undo for text (when a text view is being
// typed in) and hands everything else to the editor's annotation undo.
// ─────────────────────────────────────────────────────────────────────────────

final class EditorWindow: NSWindow {
    weak var editor: EditorWindowController?

    private var isTyping: Bool { firstResponder is NSText }

    @objc func undo(_ sender: Any?) {
        if isTyping, undoManager?.canUndo == true { undoManager?.undo(); return }
        if let editor, editor.canUndoAnnotation { editor.undo(sender); return }
        undoManager?.undo()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            if isTyping, let manager = undoManager, manager.canUndo {
                menuItem.title = manager.undoMenuItemTitle
                return true
            }
            if let editor, editor.validateMenuItem(menuItem) { return true }
            menuItem.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo ?? false
        }
        return super.validateMenuItem(menuItem)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Guide editor (the studio)
//
// Recording gets the pictures and the rough words; this window is where a
// recording becomes something you would actually hand to someone.
//
//   ┌ title ─────────────────────────────────────────────────────────────┐
//   │ steps  │ tools · crop · spotlight · colours          │ inspector   │
//   │ list   │ canvas                                      │ step text   │
//   │        │ transport + trim (steps with footage)       │ media, image│
//   │ ↑ ↓ 🗑 │ ‹ › caption                                 │ covers, draw│
//   └ status ─────────────────────────── Expand · New · Gmail · Export ─┘
//
// Three panes in one NSSplitView. The step list must stay the first
// NSTableView in the view tree — `--selftest-offline` finds it that way.
//
// A normal window, not a modal — Scribe is an accessory app, and modal loops
// from one of those can block behind other windows. Every question it asks is
// a sheet.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class EditorWindowController: NSWindowController,
                                    NSTableViewDataSource, NSTableViewDelegate,
                                    NSTextFieldDelegate, NSTextViewDelegate,
                                    NSSplitViewDelegate, NSWindowDelegate,
                                    NSMenuItemValidation {

    private let guide: Guide

    // Panes
    let table = StepTableView()
    private let split = NSSplitView()
    private var listPane = NSView()
    private var centrePane = NSView()
    private var inspectorPane = NSView()
    private var headingBar = NSView()
    private var headingRule = HairlineView()
    private var splitTopNormal: NSLayoutConstraint?
    private var splitTopExpanded: NSLayoutConstraint?

    // Heading and bottom bar
    private let titleField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let stepCountLabel = NSTextField(labelWithString: "")
    private var expandButton = NSButton()
    private var gmailButton = NSButton()
    private var exportButton = NSPopUpButton()
    private var upButton = NSButton()
    private var downButton = NSButton()
    private var deleteButton = NSButton()

    // Centre
    let canvas = MarkupCanvas()
    private let stage = StageView()
    private let placeholder = NSTextField(labelWithString: "")
    private let toolControl = NSSegmentedControl()
    let modeControl = NSSegmentedControl()
    private var swatches: [SwatchView] = []
    private var drawStrip = NSStackView()
    private var cropStrip = NSStackView()
    private let aspectControl = NSSegmentedControl()
    let cropApplyButton = NSButton()
    private let caption = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private var previousButton = NSButton()
    private var nextButton = NSButton()

    // Transport
    private var transport = NSView()
    private let playButton = NSButton()
    let scrubber = NSSlider()
    private lazy var scrubberLane = ScrubberLane(slider: scrubber)
    private let timeLabel = NSTextField(labelWithString: "")
    let trimBar = TrimBar()
    private let trimLabel = NSTextField(labelWithString: "")
    private var useStillButton = NSButton()
    private var revertStillButton = NSButton()

    // Inspector
    private var inspectorStack = NSStackView()
    private let inspectorEmpty = NSTextField(labelWithString: "")
    let noteView = PlaceholderTextView()
    private let noteFrame = FieldFrameView()
    private let contextLabel = NSTextField(wrappingLabelWithString: "")
    let mediaControl = NSSegmentedControl()
    private let clipInfo = NSTextField(wrappingLabelWithString: "")
    private let pointerToggle = NSButton(checkboxWithTitle: "Show pointer and clicks",
                                         target: nil, action: nil)
    private var cropButton = NSButton()
    private var resetCropButton = NSButton()
    let spotlightControl = NSSegmentedControl()
    private let zoomSlider = NSSlider()
    private let zoomValue = NSTextField(labelWithString: "")
    private var replaceButton = NSPopUpButton()
    private let highlightToggle = NSButton(checkboxWithTitle: "Auto highlight", target: nil, action: nil)
    private let browserChromeToggle = NSButton(checkboxWithTitle: "Hide browser tabs & address bar",
                                               target: nil, action: nil)
    private let stylePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var coversAllButton = NSButton()
    private var permanentButton = NSButton()
    private var undoButton = NSButton()
    private var clearButton = NSButton()

    // State
    private var isExpanded = false
    private var didPlaceDividers = false
    private var savedPaneWidths: (list: CGFloat, inspector: CGFloat) = (listWidth, inspectorWidth)
    /// The step the canvas and inspector are showing. By identity, not row:
    /// a drag-reorder moves rows under it.
    private var loadedStepID: UUID?
    /// The step the text view is editing, for the same reason.
    private var noteStepID: UUID?
    private var noteTimer: Timer?
    private let player = ClipPlayer()
    private(set) var playTime: Double = 0
    private var playTimer: Timer?
    private var lastDrawTool = 0
    private var suppressSelection = false
    private var isBusy = false
    private var keyMonitor: Any?

    /// Called when the user asks for a new guide. Starting one is the app
    /// delegate's job — it owns the recording state and must refuse
    /// mid-recording.
    var onNewGuide: (() -> Void)?

    private static let rowHeight: CGFloat = 64
    private static let listWidth: CGFloat = 250
    private static let inspectorWidth: CGFloat = 300
    private static let dragType = NSPasteboard.PasteboardType("com.ethantruslow.scribe.step-row")
    private static let aspects: [(String, CGFloat?)] = [("Free", nil), ("16:9", 16.0 / 9.0),
                                                        ("4:3", 4.0 / 3.0), ("1:1", 1)]

    init(guide: Guide) {
        self.guide = guide
        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Scribe — Guide Editor"
        window.minSize = NSSize(width: 1060, height: 640)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.editor = self
        window.contentView = buildContent()
        window.delegate = self

        player.onFrame = { [weak self] time, image in self?.frameArrived(time, image) }

        NotificationCenter.default.addObserver(
            forName: Guide.didChange, object: nil, queue: .main) { [weak self] note in
                let kind = note.userInfo?["kind"] as? String
                let index = note.userInfo?["index"] as? Int
                MainActor.assumeIsolated { self?.guideChanged(kind: kind, index: index) }
            }

        // Space plays, ↩ and esc finish a crop — but never while a text view
        // is being typed in, where those keys belong to the text.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
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
        placeDividersIfNeeded()
        // Otherwise the window opens with the guide title as first responder
        // and its text selected, which reads as "rename this now".
        window.makeFirstResponder(table)
    }

    func windowDidResize(_ notification: Notification) { placeDividersIfNeeded() }

    func windowWillClose(_ notification: Notification) {
        commitNote()
        pause()
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
        headingBar = buildHeading()
        let bottomRule = HairlineView()
        let bar = buildBottomBar()

        listPane = buildListPane()
        centrePane = buildCentrePane()
        inspectorPane = buildInspectorPane()

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        [listPane, centrePane, inspectorPane].forEach(split.addArrangedSubview)
        // The centre gives way first when the window is resized (see also
        // `shouldAdjustSizeOfSubview`, which is what actually holds); the side
        // panes keep the width you gave them.
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 2)

        let root = NSView()
        [headingBar, headingRule, split, bottomRule, bar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        let normal = split.topAnchor.constraint(equalTo: headingRule.bottomAnchor)
        splitTopNormal = normal
        splitTopExpanded = split.topAnchor.constraint(equalTo: root.topAnchor)
        NSLayoutConstraint.activate([
            headingBar.topAnchor.constraint(equalTo: root.topAnchor),
            headingBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headingBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            headingRule.topAnchor.constraint(equalTo: headingBar.bottomAnchor),
            headingRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headingRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headingRule.heightAnchor.constraint(equalToConstant: 1),

            normal,
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),

            bottomRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomRule.heightAnchor.constraint(equalToConstant: 1),
            bottomRule.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 46),
        ])
        return root
    }

    private func buildHeading() -> NSView {
        titleField.stringValue = guide.title
        titleField.font = .systemFont(ofSize: 20, weight: .semibold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none          // it is a heading, not an input box
        titleField.placeholderString = "Guide title"
        titleField.delegate = self
        titleField.tag = -1
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleHint = NSTextField(labelWithString:
            "Click the title to rename the guide. Rewrite a step’s text in the inspector on the right.")
        titleHint.font = .systemFont(ofSize: 11)
        titleHint.textColor = .tertiaryLabelColor
        titleHint.lineBreakMode = .byTruncatingTail
        titleHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleField, titleHint])
        stack.orientation = .vertical
        stack.spacing = 1
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -18),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        return bar
    }

    // MARK: Layout — step list

    private func buildListPane() -> NSView {
        let pane = NSVisualEffectView()
        pane.material = .sidebar
        pane.blendingMode = .behindWindow
        pane.state = .followsWindowActiveState

        let heading = sectionHeader("Steps")
        stepCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stepCountLabel.textColor = .tertiaryLabelColor
        let header = NSStackView(views: [heading, NSView(), stepCountLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .inset
        table.backgroundColor = .clear
        // Alternating colours over tall rows read as random blocks rather than
        // as a striped list. A hairline between rows does the same job quietly.
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []          // see SeparatorRowView
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.allowsTypeSelect = false    // Space is play/pause, not a search
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        table.onDelete = { [weak self] in self?.deleteStep() }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("step"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        upButton     = iconButton("chevron.up", "Move step up", #selector(moveStepUp))
        downButton   = iconButton("chevron.down", "Move step down", #selector(moveStepDown))
        deleteButton = iconButton("trash", "Delete this step (⌫)", #selector(deleteStep))
        let footer = NSStackView(views: [upButton, downButton, NSView(), deleteButton])
        footer.orientation = .horizontal
        footer.spacing = 2
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerRule = HairlineView()
        footerRule.translatesAutoresizingMaskIntoConstraints = false

        [header, scroll, footerRule, footer].forEach(pane.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor),

            footerRule.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerRule.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -5),

            footer.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -5),
            footer.heightAnchor.constraint(equalToConstant: 26),
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        return pane
    }

    // MARK: Layout — canvas

    private func buildCentrePane() -> NSView {
        let strip = buildToolStrip()
        let stripRule = HairlineView()

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onAddRedaction = { [weak self] rect, colour in self?.addRedaction(rect, color: colour) }
        canvas.onAddMarkup = { [weak self] markup in self?.addMarkup(markup) }
        canvas.onRemove = { [weak self] point in self?.removeAnnotation(at: point) }
        canvas.onSpotlightArea = { [weak self] rect in self?.spotlightAreaDrawn(rect) }
        canvas.onMoveMagnifier = { [weak self] point in self?.magnifierMoved(to: point) }

        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 0
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(canvas)
        stage.addSubview(placeholder)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: stage.topAnchor, constant: 18),
            canvas.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -18),
            canvas.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 22),
            canvas.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -22),
            placeholder.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: stage.leadingAnchor, constant: 24),
        ])

        transport = buildTransport()
        let captionRow = buildCaptionRow()

        let column = NSStackView(views: [strip, stripRule, stage, transport, captionRow])
        column.orientation = .vertical
        column.spacing = 0
        column.distribution = .fill
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        stage.setContentHuggingPriority(.init(1), for: .vertical)
        stage.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let pane = NSView()
        pane.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: pane.topAnchor),
            column.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
        ])
        // Not required: the split delegate keeps the centre at least this
        // wide, and if the window ever forces it narrower the strip clips
        // rather than the layout breaking.
        let minimum = pane.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.centreMinimum)
        minimum.priority = .defaultHigh
        minimum.isActive = true
        pane.clipsToBounds = true
        for view in [strip, stripRule, stage, transport, captionRow] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return pane
    }

    /// Tools over the picture they act on. The same strip turns into the crop
    /// bar while cropping, so Apply is where your eyes already are.
    private func buildToolStrip() -> NSView {
        toolControl.segmentCount = CanvasTool.all.count
        toolControl.trackingMode = .selectOne
        for (i, tool) in CanvasTool.all.enumerated() {
            if let image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label) {
                toolControl.setImage(image, forSegment: i)
            } else {
                toolControl.setLabel(tool.label, forSegment: i)
            }
            toolControl.setToolTip(tool.tip, forSegment: i)
            toolControl.setWidth(30, forSegment: i)
        }
        toolControl.selectedSegment = 0
        toolControl.target = self
        toolControl.action = #selector(toolChanged)

        modeControl.segmentCount = 2
        modeControl.trackingMode = .selectOne
        for (i, (symbol, label, tip)) in [
            ("crop", "Crop", "Crop — trim the picture to what matters (↩ applies, esc cancels)"),
            ("flashlight.on.fill", "Spotlight",
             "Spotlight — dim everything except one area, or magnify it"),
        ].enumerated() {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
                modeControl.setImage(image, forSegment: i)
            } else {
                modeControl.setLabel(label, forSegment: i)
            }
            modeControl.setToolTip(tip, forSegment: i)
            modeControl.setWidth(30, forSegment: i)
        }
        modeControl.selectedSegment = -1
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        // Colour swatches rather than a popup: you pick a colour constantly
        // while drawing, and a menu costs two clicks every time.
        swatches = MarkupColor.allCases.map { colour in
            let view = SwatchView(colour)
            view.onPick = { [weak self] picked in self?.colorPicked(picked) }
            return view
        }
        let swatchRow = NSStackView(views: swatches)
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 1

        drawStrip = NSStackView(views: [toolControl, verticalRule(), modeControl, verticalRule(), swatchRow])
        drawStrip.orientation = .horizontal
        drawStrip.spacing = 10
        drawStrip.alignment = .centerY

        // The crop bar.
        let aspectLabel = NSTextField(labelWithString: "Aspect")
        aspectLabel.font = .systemFont(ofSize: 11)
        aspectLabel.textColor = .secondaryLabelColor
        aspectControl.segmentCount = Self.aspects.count
        aspectControl.trackingMode = .selectOne
        aspectControl.controlSize = .small
        aspectControl.font = .systemFont(ofSize: 11)
        for (i, aspect) in Self.aspects.enumerated() { aspectControl.setLabel(aspect.0, forSegment: i) }
        aspectControl.selectedSegment = 0
        aspectControl.target = self
        aspectControl.action = #selector(aspectChanged)

        let cropTitle = NSTextField(labelWithString: "Crop")
        cropTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let reset = textButton("Reset", #selector(resetCropSelection), "Select the whole picture again.")
        let cancel = textButton("Cancel", #selector(cancelCrop), "Leave the crop as it was (esc).")
        cropApplyButton.title = "Apply"
        cropApplyButton.bezelStyle = .rounded
        cropApplyButton.target = self
        cropApplyButton.action = #selector(applyCrop)
        cropApplyButton.bezelColor = .controlAccentColor
        cropApplyButton.toolTip = "Crop to the frame (↩). Nothing is thrown away — Reset Crop brings it back."
        cropStrip = NSStackView(views: [cropTitle, aspectLabel, aspectControl, NSView(),
                                        reset, cancel, cropApplyButton])
        cropStrip.orientation = .horizontal
        cropStrip.spacing = 8
        cropStrip.alignment = .centerY
        cropStrip.setCustomSpacing(16, after: cropTitle)
        cropStrip.isHidden = true

        let strip = NSView()
        for s in [drawStrip, cropStrip] {
            s.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(s)
        }
        NSLayoutConstraint.activate([
            strip.heightAnchor.constraint(equalToConstant: 42),
            drawStrip.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 14),
            drawStrip.trailingAnchor.constraint(lessThanOrEqualTo: strip.trailingAnchor, constant: -14),
            drawStrip.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            cropStrip.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 14),
            cropStrip.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -14),
            cropStrip.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
        updateSwatches()
        return strip
    }

    private func buildTransport() -> NSView {
        playButton.isBordered = false
        playButton.imageScaling = .scaleProportionallyUpOrDown
        playButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playButton.toolTip = "Play or pause the clip (Space)"
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        playButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        scrubber.minValue = 0
        scrubber.maxValue = 1
        scrubber.isContinuous = true
        scrubber.controlSize = .small
        scrubber.target = self
        scrubber.action = #selector(scrubbed(_:))
        scrubber.toolTip = "Scrub through the part of the clip that will play"

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        trimLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        trimLabel.textColor = .secondaryLabelColor
        trimLabel.alignment = .right
        trimLabel.setContentHuggingPriority(.required, for: .horizontal)

        trimBar.toolTip = "Drag the handles to choose where the GIF starts and ends. Red dots are clicks."
        trimBar.onChange = { [weak self] start, end in self?.trimDragged(start: start, end: end) }
        trimBar.onCommit = { [weak self] start, end in self?.trimCommitted(start: start, end: end) }
        trimBar.onScrub = { [weak self] time in self?.scrub(to: time) }
        trimBar.onGeometryChange = { [weak self] in self?.scrubberLane.needsLayout = true }
        scrubberLane.trimBar = trimBar

        useStillButton = textButton("Use as Still", #selector(useFrameAsStill),
                                    "Make the frame you are looking at this step’s screenshot.")
        revertStillButton = textButton("Revert Still", #selector(revertStill),
                                       "Go back to the screenshot the step was recorded with.")

        let stillButtons = NSStackView(views: [useStillButton, revertStillButton])
        stillButtons.orientation = .horizontal
        stillButtons.spacing = 6

        // A grid, so the scrubber and the trim bar share one column and read
        // as the same timeline, one above the other.
        let grid = NSGridView(views: [[playButton, scrubberLane, timeLabel],
                                      [trimLabel, trimBar, stillButtons]])
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.rowAlignment = .none
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 1).yPlacement = .center
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        trimBar.setContentHuggingPriority(.init(1), for: .horizontal)
        scrubberLane.setContentHuggingPriority(.init(1), for: .horizontal)
        let rule = HairlineView()
        rule.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.addSubview(rule)
        bar.addSubview(grid)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: bar.topAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            grid.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -8),
            grid.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
        ])
        return bar
    }

    private func buildCaptionRow() -> NSView {
        // Without these, Expand traps you on one step — the list you would
        // otherwise click is exactly what got collapsed.
        previousButton = iconButton("chevron.left", "Previous step", #selector(previousStep))
        nextButton = iconButton("chevron.right", "Next step", #selector(nextStep))

        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(100), for: .horizontal)

        let row = NSStackView(views: [previousButton, nextButton, caption, NSView(), hint])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.setCustomSpacing(8, after: nextButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        let rule = HairlineView()
        rule.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.addSubview(rule)
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 34),
            rule.topAnchor.constraint(equalTo: bar.topAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 0.5),
        ])
        return bar
    }

    // MARK: Layout — inspector

    private func buildInspectorPane() -> NSView {
        // Step
        noteView.delegate = self
        noteView.isRichText = false
        noteView.importsGraphics = false
        noteView.allowsUndo = true
        // The Writing Tools badge sits on the frame's left edge, over the
        // first word — in a 300 pt inspector there is no margin for it.
        if #available(macOS 15.1, *) { noteView.writingToolsBehavior = .none }
        noteView.font = .systemFont(ofSize: 13)
        noteView.textColor = .labelColor
        noteView.drawsBackground = false
        noteView.textContainerInset = NSSize(width: 4, height: 6)
        noteView.isVerticallyResizable = true
        noteView.isHorizontallyResizable = false
        noteView.autoresizingMask = [.width]
        noteView.minSize = NSSize(width: 0, height: 0)
        noteView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        noteView.textContainer?.widthTracksTextView = true
        noteView.textContainer?.containerSize = NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude)
        let noteScroll = NSScrollView()
        noteScroll.documentView = noteView
        noteScroll.hasVerticalScroller = true
        noteScroll.autohidesScrollers = true
        noteScroll.drawsBackground = false
        noteScroll.borderType = .noBorder
        noteScroll.translatesAutoresizingMaskIntoConstraints = false
        noteFrame.addSubview(noteScroll)
        noteFrame.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noteScroll.topAnchor.constraint(equalTo: noteFrame.topAnchor, constant: 3),
            noteScroll.bottomAnchor.constraint(equalTo: noteFrame.bottomAnchor, constant: -3),
            noteScroll.leadingAnchor.constraint(equalTo: noteFrame.leadingAnchor, constant: 3),
            noteScroll.trailingAnchor.constraint(equalTo: noteFrame.trailingAnchor, constant: -3),
            noteFrame.heightAnchor.constraint(equalToConstant: 96),
        ])
        contextLabel.font = .systemFont(ofSize: 11)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.maximumNumberOfLines = 3
        let noteHint = smallNote("↩ saves · ⌥↩ for a new line")

        // Media
        mediaControl.segmentCount = 2
        mediaControl.setLabel("Screenshot", forSegment: 0)
        mediaControl.setLabel("GIF", forSegment: 1)
        mediaControl.trackingMode = .selectOne
        mediaControl.segmentDistribution = .fillEqually
        mediaControl.controlSize = .small
        mediaControl.target = self
        mediaControl.action = #selector(mediaChanged(_:))
        clipInfo.font = .systemFont(ofSize: 11)
        clipInfo.textColor = .secondaryLabelColor
        pointerToggle.target = self
        pointerToggle.action = #selector(togglePointer)
        pointerToggle.controlSize = .small
        pointerToggle.font = .systemFont(ofSize: 11)
        pointerToggle.toolTip = "Draw the mouse pointer and a ripple on each click in the GIF."

        // Image
        cropButton = textButton("Crop…", #selector(beginCropFromInspector),
                                "Trim the picture to what matters. Nothing is thrown away.")
        resetCropButton = textButton("Reset Crop", #selector(resetCrop), "Show the whole picture again.")
        let cropRow = equalRow([cropButton, resetCropButton])

        spotlightControl.segmentCount = 3
        for (i, label) in ["None", "Dim", "Magnify"].enumerated() {
            spotlightControl.setLabel(label, forSegment: i)
        }
        spotlightControl.trackingMode = .selectOne
        spotlightControl.segmentDistribution = .fillEqually
        spotlightControl.controlSize = .small
        spotlightControl.target = self
        spotlightControl.action = #selector(spotlightChanged)
        spotlightControl.setToolTip("Darken everything outside the area", forSegment: 1)
        spotlightControl.setToolTip("Darken outside, and show the area enlarged in an inset", forSegment: 2)

        zoomSlider.minValue = 1.5
        zoomSlider.maxValue = 4
        zoomSlider.doubleValue = 2
        zoomSlider.isContinuous = false
        zoomSlider.controlSize = .small
        zoomSlider.numberOfTickMarks = 6
        zoomSlider.allowsTickMarkValuesOnly = true
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged)
        zoomValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomValue.textColor = .secondaryLabelColor
        zoomValue.alignment = .right
        zoomValue.translatesAutoresizingMaskIntoConstraints = false
        zoomValue.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let zoomRow = NSStackView(views: [smallLabel("Zoom"), zoomSlider, zoomValue])
        zoomRow.orientation = .horizontal
        zoomRow.spacing = 8

        replaceButton = NSPopUpButton(frame: .zero, pullsDown: true)
        replaceButton.addItems(withTitles: ["Replace Image", "From File…", "From Clipboard"])
        replaceButton.item(at: 1)?.action = #selector(replaceFromFile)
        replaceButton.item(at: 2)?.action = #selector(replaceFromClipboard)
        replaceButton.item(at: 1)?.target = self
        replaceButton.item(at: 2)?.target = self
        replaceButton.controlSize = .small
        replaceButton.font = .systemFont(ofSize: 11)
        replaceButton.toolTip = "Swap in a different picture. The step keeps its text."

        highlightToggle.target = self
        highlightToggle.action = #selector(toggleAutoHighlight)
        highlightToggle.controlSize = .small
        highlightToggle.font = .systemFont(ofSize: 11)
        highlightToggle.toolTip = "The automatic red box or ring. Turn it off when it "
            + "landed on the wrong thing and you have drawn your own."

        browserChromeToggle.target = self
        browserChromeToggle.action = #selector(toggleBrowserChrome)
        browserChromeToggle.controlSize = .small
        browserChromeToggle.font = .systemFont(ofSize: 11)
        browserChromeToggle.toolTip = "Crop this step to the web page. Only for steps recorded "
            + "in a browser; switching it off removes the crop."

        // Covers
        for style in [RedactionStyle.solid, .pixelate] { stylePicker.addItem(withTitle: style.label) }
        stylePicker.selectItem(at: 0)
        stylePicker.controlSize = .small
        stylePicker.font = .systemFont(ofSize: 11)
        stylePicker.target = self
        stylePicker.action = #selector(styleChanged)
        stylePicker.toolTip = "A solid bar gives nothing away and is the safe choice. "
            + "Pixelation still shows shape and colour — fine for hiding clutter, "
            + "not for anything that matters if it is recovered."
        let styleRow = NSStackView(views: [smallLabel("New covers"), stylePicker])
        styleRow.orientation = .horizontal
        styleRow.spacing = 8
        coversAllButton = textButton("Copy Covers to All Steps", #selector(applyRedactionsEverywhere),
                                     "Copy this step’s covers onto every other step — for a sidebar or "
                                     + "header that appears in all of them. Drawings are not copied.")
        permanentButton = textButton("Make Permanent…", #selector(flattenRedactions),
                                     "Write the covers into the saved screenshots. "
                                     + "Until you do, the originals on disk still show everything.")

        // Drawing
        undoButton = textButton("Undo", #selector(undoAnnotation), "Remove the last thing added (⌘Z).")
        clearButton = textButton("Clear All", #selector(clearAnnotations),
                                 "Remove every cover and drawing on this step.")

        let sections: [NSView] = [
            section("Step", [noteFrame, noteHint, contextLabel]),
            section("Media", [mediaControl, clipInfo, pointerToggle]),
            section("Image", [cropRow, smallLabel("Spotlight"), spotlightControl, zoomRow,
                              replaceButton, highlightToggle, browserChromeToggle]),
            section("Covers", [styleRow, coversAllButton, permanentButton]),
            section("Drawing", [equalRow([undoButton, clearButton])]),
        ]
        var arranged: [NSView] = []
        for (i, s) in sections.enumerated() {
            if i > 0 { arranged.append(HairlineView()) }
            arranged.append(s)
        }
        inspectorStack = NSStackView(views: arranged)
        inspectorStack.orientation = .vertical
        inspectorStack.alignment = .leading
        inspectorStack.spacing = 0
        inspectorStack.translatesAutoresizingMaskIntoConstraints = false
        for view in arranged {
            view.widthAnchor.constraint(equalTo: inspectorStack.widthAnchor).isActive = true
        }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(inspectorStack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            inspectorStack.topAnchor.constraint(equalTo: document.topAnchor),
            inspectorStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            inspectorStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            inspectorStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        inspectorEmpty.font = .systemFont(ofSize: 12)
        inspectorEmpty.textColor = .tertiaryLabelColor
        inspectorEmpty.alignment = .center
        inspectorEmpty.stringValue = "Nothing selected"
        inspectorEmpty.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        pane.addSubview(scroll)
        pane.addSubview(inspectorEmpty)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: pane.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            inspectorEmpty.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            inspectorEmpty.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        return pane
    }

    /// A titled group of inspector rows, every row stretched to the width.
    private func section(_ title: String, _ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: [sectionHeader(title)] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews[0])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        return stack
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
        ])
        return label
    }

    private func smallLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func smallNote(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10.5)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func equalRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }

    private func verticalRule() -> NSView {
        let rule = HairlineView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        rule.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return rule
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    private func textButton(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.toolTip = tip
        return b
    }

    // MARK: Layout — bottom bar

    private func buildBottomBar() -> NSView {
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)

        expandButton = NSButton(title: "Expand", target: self, action: #selector(toggleExpanded))
        expandButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                                     accessibilityDescription: "Expand")
        expandButton.imagePosition = .imageLeading
        expandButton.bezelStyle = .rounded
        expandButton.toolTip = "Give the picture the whole window. The panels come back "
            + "when you switch off; ‹ › under the picture still change step."

        let newGuide = NSButton(title: "New Guide", target: self, action: #selector(newGuide))
        newGuide.bezelStyle = .rounded
        newGuide.toolTip = "Start an empty guide. This one is saved and stays in the library."

        gmailButton = NSButton(title: "Copy for Gmail", target: self, action: #selector(copyForGmail))
        gmailButton.bezelStyle = .rounded
        gmailButton.toolTip = "Copy the whole guide, formatted, ready to paste into a Gmail message."

        exportButton = NSPopUpButton(frame: .zero, pullsDown: true)
        exportButton.addItems(withTitles: ["Export", "Web page (.html)",
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
        let row = NSStackView(views: [statusLabel, spacer, expandButton, verticalRule(),
                                      newGuide, gmailButton, exportButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.setCustomSpacing(12, after: expandButton)
        row.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    // MARK: Split view
    //
    // NSSplitView ignores its arranged subviews' own constraints for the
    // initial divider positions, so they get set once, after the window has a
    // real width to divide.

    private func placeDividersIfNeeded() {
        guard !didPlaceDividers, !isExpanded, split.frame.width > 700 else { return }
        didPlaceDividers = true
        split.setPosition(Self.listWidth, ofDividerAt: 0)
        split.setPosition(split.frame.width - Self.inspectorWidth - split.dividerThickness,
                          ofDividerAt: 1)
    }

    private static let listRange: ClosedRange<CGFloat> = 230...380
    private static let inspectorRange: ClosedRange<CGFloat> = 260...400
    private static let centreMinimum: CGFloat = 460

    /// While expanded both side panes are hidden (a hidden arranged subview
    /// is a collapsed one), and the limits have to yield — a delegate still
    /// insisting on a minimum is what made `setPosition(0, …)` do nothing.
    /// Otherwise each side pane stays in its range and the centre always
    /// keeps room for the tool strip.
    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposed: CGFloat,
                   ofSubviewAt index: Int) -> CGFloat {
        if isExpanded { return proposed }
        let width = splitView.frame.width
        if index == 0 { return Self.listRange.lowerBound }
        let listEdge = listPane.isHidden ? 0 : listPane.frame.maxX
        return max(width - Self.inspectorRange.upperBound, listEdge + Self.centreMinimum)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposed: CGFloat,
                   ofSubviewAt index: Int) -> CGFloat {
        if isExpanded { return proposed }
        let width = splitView.frame.width
        if index == 0 {
            let inspector = inspectorPane.isHidden ? 0 : inspectorPane.frame.width + splitView.dividerThickness
            return max(min(Self.listRange.upperBound, width - inspector - Self.centreMinimum),
                       Self.listRange.lowerBound)
        }
        return width - Self.inspectorRange.lowerBound
    }

    /// Implementing the constrain methods above puts NSSplitView on its older
    /// resizing path, which ignores holding priorities and shrinks all three
    /// panes in proportion — at the minimum window size that squeezed the step
    /// list until its text broke mid-word. Only the centre follows the window.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === centrePane
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === listPane || subview === inspectorPane
    }

    /// For `--shot-expanded` and `--shot-studio`, which cannot click the button.
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        toggleExpanded()
    }

    /// Collapses both side panes so the picture gets the window.
    @objc private func toggleExpanded() {
        // The flag first: the split delegate consults it, and a limit that
        // has not yielded yet silently refuses the new divider positions.
        isExpanded.toggle()
        if isExpanded {
            if !listPane.isHidden && !inspectorPane.isHidden {
                savedPaneWidths = (listPane.frame.width, inspectorPane.frame.width)
            }
            listPane.isHidden = true
            inspectorPane.isHidden = true
            headingBar.isHidden = true
            headingRule.isHidden = true
            splitTopNormal?.isActive = false
            splitTopExpanded?.isActive = true
        } else {
            splitTopExpanded?.isActive = false
            splitTopNormal?.isActive = true
            headingBar.isHidden = false
            headingRule.isHidden = false
            listPane.isHidden = false
            inspectorPane.isHidden = false
            window?.contentView?.layoutSubtreeIfNeeded()
            let list = savedPaneWidths.list > 150 ? savedPaneWidths.list : Self.listWidth
            let inspector = savedPaneWidths.inspector > 150 ? savedPaneWidths.inspector : Self.inspectorWidth
            split.adjustSubviews()
            split.setPosition(list, ofDividerAt: 0)
            split.setPosition(split.frame.width - inspector - split.dividerThickness, ofDividerAt: 1)
        }
        expandButton.title = isExpanded ? "Show Panels" : "Expand"
        expandButton.image = NSImage(systemSymbolName: isExpanded ? "arrow.down.right.and.arrow.up.left"
                                                                  : "arrow.up.left.and.arrow.down.right",
                                     accessibilityDescription: expandButton.title)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { guide.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard guide.steps.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: StepCellView.identifier, owner: nil)
            as? StepCellView ?? StepCellView()
        cell.configure(guide.steps[row], row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = SeparatorRowView()
        rowView.lineInset = 10
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        loadSelectedStep()
    }

    // MARK: Rows — drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === table else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let from = Int(text), guide.steps.indices.contains(from) else { return false }
        // `row` is a gap in the old order; `move(from:to:)` wants the index in
        // the new one, which is one less when moving downwards.
        let to = from < row ? row - 1 : row
        guard to != from else { return false }
        commitNote()
        let landed = guide.move(from: from, to: to)
        select(landed)
        return true
    }

    // MARK: Text

    /// The title. Step text lives in the inspector's text view instead; the
    /// canvas's inline label field has its own delegate.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === titleField || field.tag == -1 else { return }
        guide.title = titleField.stringValue.isEmpty ? "Untitled Guide" : titleField.stringValue
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === noteView else { return }
        // Saving on every keystroke rewrites guide.json per character and
        // reloads the row under your fingers; 0.4 s after you pause is enough.
        noteTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitNote() }
        }
        RunLoop.main.add(timer, forMode: .common)
        noteTimer = timer
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard (notification.object as? NSTextView) === noteView else { return }
        noteFrame.isFocused = true
    }

    func textDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextView) === noteView else { return }
        noteFrame.isFocused = false
        commitNote()
    }

    /// Return finishes the step, like the table field it replaced; ⌥Return
    /// is the way to a second line.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === noteView else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.cancelOperation(_:)):
            commitNote()
            window?.makeFirstResponder(table)
            return true
        default:
            return false
        }
    }

    /// Writes the text view into the step it was editing — found by identity,
    /// so a reorder in the meantime cannot land the words on the wrong step.
    private func commitNote() {
        noteTimer?.invalidate()
        noteTimer = nil
        guard let id = noteStepID,
              let row = guide.steps.firstIndex(where: { $0.id == id }) else { return }
        let step = guide.steps[row]
        let typed = noteView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typing back exactly the auto sentence means "I am happy with it", not
        // "this is my hand-written text" — store nothing and stay grey.
        let value = typed == step.autoText ? "" : typed
        guard value != step.note else { return }
        guide.setNote(value, at: row)
    }

    private var isEditingNote: Bool { window?.firstResponder === noteView }

    /// Loads the selected step's note into the text view — never over the top
    /// of typing in progress. Moving to another step while typing commits the
    /// old one first and then ends that editing session.
    private func syncNoteView() {
        guard let step = currentStep else {
            if isEditingNote { commitNote(); window?.makeFirstResponder(table) }
            noteStepID = nil
            noteView.string = ""
            return
        }
        noteView.placeholder = step.autoText
        if noteStepID != step.id {
            if isEditingNote { commitNote(); window?.makeFirstResponder(table) }
            noteStepID = step.id
            noteView.string = step.note
            // The text view types into the window's undo manager. Its history
            // belongs to the step it was typed for; ⌘Z must not replay the
            // last step's sentence into this one.
            window?.undoManager?.removeAllActions()
        } else if !isEditingNote, noteView.string != step.note {
            noteView.string = step.note
        }
    }

    // MARK: Model notifications
    //
    // `Guide.changed` says what kind of edit it was, so a keystroke in the
    // step text reloads one row and not the whole table (which would also
    // re-render every thumbnail), and a cover redraws one picture.

    private func guideChanged(kind raw: String?, index: Int?) {
        let kind = raw.flatMap(Guide.Change.init(rawValue:)) ?? .structure
        // A row count that no longer matches means something structural
        // happened whatever the label says; reload rather than index past it.
        if kind == .structure || table.numberOfRows != guide.count {
            refresh()
            return
        }
        switch kind {
        case .structure:
            refresh()
        case .title:
            if titleField.currentEditor() == nil { titleField.stringValue = guide.title }
        case .text:
            reloadRows(index)
            if index == nil || index == table.selectedRow {
                syncNoteView()
                updateCaption()
            }
        case .image:
            reloadRows(index)
            if index == nil || index == table.selectedRow { selectedStepImageChanged() }
        }
    }

    private func reloadRows(_ index: Int?) {
        let rows: IndexSet = index.map { IndexSet(integer: $0) }
            ?? IndexSet(integersIn: 0..<guide.count)
        let valid = rows.filteredIndexSet { $0 < table.numberOfRows }
        guard !valid.isEmpty else { return }
        table.reloadData(forRowIndexes: valid, columnIndexes: IndexSet(integer: 0))
    }

    // MARK: Refresh

    func refresh() {
        let previousRow = table.selectedRow
        suppressSelection = true
        table.reloadData()
        // Something is always selected when there is anything to select. The
        // first version left the preview permanently blank on open because it
        // waited for the user to click a row first. The same step stays
        // selected across a reorder; a deleted one hands over to its neighbour.
        if guide.count > 0 {
            let byID = loadedStepID.flatMap { id in guide.steps.firstIndex { $0.id == id } }
            select(byID ?? min(max(previousRow, 0), guide.count - 1))
        }
        suppressSelection = false
        if titleField.currentEditor() == nil { titleField.stringValue = guide.title }
        loadSelectedStep()
        stepCountLabel.stringValue = guide.isEmpty ? "" : "\(guide.count)"
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

    private var currentRow: Int? {
        let row = table.selectedRow
        return guide.steps.indices.contains(row) ? row : nil
    }

    private var currentStep: GuideStep? { currentRow.map { guide.steps[$0] } }

    /// Everything the selected step drives: canvas, player, transport,
    /// inspector, caption. A different step than last time also resets the
    /// per-step state — playback, crop mode, the playhead.
    private func loadSelectedStep() {
        guard let step = currentStep, let row = currentRow else {
            loadedStepID = nil
            if canvas.mode == .crop { endCrop(apply: false, render: false) }
            pause()
            player.load(nil)
            syncNoteView()
            showEmptyState()
            return
        }
        if step.id != loadedStepID {
            pause()
            if canvas.mode == .crop { endCrop(apply: false, render: false) }
            loadedStepID = step.id
            playTime = step.gif?.trimStart ?? 0
        }
        placeholder.isHidden = true
        canvas.isHidden = false
        player.load(step.hasFootage ? step.renderSpec(number: row + 1) : nil)
        clampPlayTime()
        renderCanvas()
        syncNoteView()
        updateInspector()
        updateTransport()
        updateCaption()
        updateButtons()
        updateToolAvailability(true)
    }

    /// Pixels changed on the selected step: re-render, and throw away every
    /// cached preview frame (the generation bump drops ones still rendering).
    private func selectedStepImageChanged() {
        guard let step = currentStep, let row = currentRow else { return }
        player.load(step.hasFootage ? step.renderSpec(number: row + 1) : nil)
        if !step.isGIF { pause() }
        clampPlayTime()
        renderCanvas()
        updateInspector()
        updateTransport()
        updateCaption()
    }

    private func showEmptyState() {
        canvas.image = nil
        canvas.redactions = []
        canvas.markups = []
        canvas.spotlight = nil
        canvas.isHidden = true
        placeholder.stringValue = guide.isEmpty
            ? "No steps yet.\n\nPress ⌃⌥⌘R and click your way through\nwhatever you want to explain."
            : "Select a step to see it here."
        placeholder.isHidden = false
        transport.isHidden = true
        inspectorStack.isHidden = true
        inspectorEmpty.isHidden = false
        inspectorEmpty.stringValue = guide.isEmpty ? "No steps yet" : "Nothing selected"
        caption.stringValue = ""
        hint.stringValue = ""
        updateButtons()
        updateToolAvailability(false)
    }

    private func updateToolAvailability(_ enabled: Bool) {
        toolControl.isEnabled = enabled
        modeControl.isEnabled = enabled
        if !enabled { swatches.forEach { $0.isUsable = false } } else { updateSwatches() }
    }

    // MARK: Canvas rendering

    /// The canvas shows, in order of precedence: the uncropped still while
    /// cropping; the current frame for a step that plays as a GIF; otherwise
    /// the finished still. Every one of them comes out of `FrameRenderer`, so
    /// covers are on them all.
    private func renderCanvas() {
        guard let step = currentStep, let row = currentRow else { return }
        canvas.redactions = step.redactions
        canvas.markups = step.markups
        canvas.spotlight = step.spotlight
        let spec = step.renderSpec(number: row + 1)
        if canvas.mode == .crop {
            canvas.displayCrop = nil
            setCanvasImage(FrameRenderer.still(spec, applyCrop: false))
        } else if step.isGIF {
            canvas.displayCrop = step.crop
            showClipFrame(sync: true)
        } else {
            canvas.displayCrop = step.crop
            setCanvasImage(FrameRenderer.still(spec))
        }
    }

    private func setCanvasImage(_ image: CGImage?) {
        canvas.image = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    /// The frame at the playhead: from the cache, rendered right now (when
    /// nothing is on screen for it yet), or requested and shown on arrival.
    private func showClipFrame(sync: Bool) {
        if let hit = player.cached(playTime) { setCanvasImage(hit); return }
        if sync, let now = player.renderNow(playTime) { setCanvasImage(now); return }
        player.request(playTime)
    }

    private func frameArrived(_ time: Double, _ image: CGImage) {
        guard currentStep?.isGIF == true, canvas.mode != .crop else { return }
        if ClipPlayer.key(time) == ClipPlayer.key(playTime) {
            setCanvasImage(image)
        } else if player.cached(playTime) == nil, playTimer == nil {
            // A scrub moved on while this one rendered; a slot is free now,
            // so ask for where the playhead actually is.
            player.request(playTime)
        }
    }

    private func clampPlayTime() {
        guard let clip = currentStep?.gif else { playTime = 0; return }
        playTime = ClipPlayer.snap(min(max(playTime, clip.trimStart), clip.trimEnd), in: clip)
    }

    // MARK: Playback

    @objc func togglePlayback() {
        if playTimer != nil { pause() } else { play() }
    }

    var isPlaying: Bool { playTimer != nil }

    private func play() {
        guard let step = currentStep, step.isGIF, let clip = step.gif, canvas.mode != .crop else { return }
        if playTime >= clip.trimEnd - 0.05 { playTime = clip.trimStart }
        let timer = Timer(timeInterval: 1 / ClipPlayer.fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so the clip keeps playing while a menu is open or a slider
        // is being dragged — both run the loop in a tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        playTimer = timer
        player.prefetch(after: playTime, clip: clip)
        updatePlayButton()
    }

    private func pause() {
        playTimer?.invalidate()
        playTimer = nil
        updatePlayButton()
    }

    /// One tenth of a second on. If the next frame has not rendered yet the
    /// playhead waits for it instead of skipping — a clip that runs slow for
    /// a moment reads better than one that stutters past a click.
    private func tick() {
        guard let step = currentStep, step.isGIF, let clip = step.gif else { pause(); return }
        var next = playTime + 1 / ClipPlayer.fps
        if next > clip.trimEnd - 0.001 { next = clip.trimStart }
        next = ClipPlayer.snap(next, in: clip)
        if let image = player.cached(next) {
            playTime = next
            setCanvasImage(image)
            updateTimeReadout()
        } else {
            player.request(next)
        }
        player.prefetch(after: playTime, clip: clip)
    }

    @objc func scrubbed(_ sender: NSSlider) {
        scrub(to: sender.doubleValue)
    }

    private func scrub(to time: Double) {
        guard let step = currentStep, step.isGIF, let clip = step.gif else { return }
        pause()
        playTime = ClipPlayer.snap(time, in: clip)
        showClipFrame(sync: false)
        updateTimeReadout()
    }

    /// For `--shot-studio`: puts the playhead `fraction` of the way through
    /// the trimmed range and renders that frame before returning.
    func scrub(toFraction fraction: Double) {
        guard let clip = currentStep?.gif else { return }
        pause()
        playTime = ClipPlayer.snap(clip.trimStart + clip.length * fraction, in: clip)
        showClipFrame(sync: true)
        updateTimeReadout()
    }

    private func trimDragged(start: Double, end: Double) {
        guard let step = currentStep, step.isGIF, let clip = step.gif else { return }
        trimLabel.stringValue = Self.seconds(end - start) + " kept"
        scrubber.minValue = start
        scrubber.maxValue = max(end, start + 0.01)
        // Show the frame at the handle being moved, so you can see where it
        // will start or stop.
        let moving = abs(start - clip.trimStart) > abs(end - clip.trimEnd) ? start : end
        pause()
        playTime = moving
        showClipFrame(sync: false)
        updateTimeReadout()
    }

    private func trimCommitted(start: Double, end: Double) {
        guard let row = currentRow else { return }
        guide.setTrim(start: start, end: end, at: row)
        updateTransport()
    }

    @objc private func useFrameAsStill() {
        guard let row = currentRow else { return }
        if guide.useFrameAsStill(at: playTime, index: row) {
            report("The frame at \(Self.clock(playTime)) is now step \(row + 1)’s screenshot.")
        } else {
            report("Could not use that frame as the screenshot.")
        }
    }

    @objc private func revertStill() {
        guard let row = currentRow else { return }
        guide.revertStill(at: row)
        report("Step \(row + 1) is back to the screenshot it was recorded with.")
    }

    // MARK: Transport, inspector, caption

    private func updateTransport() {
        guard let step = currentStep, step.hasFootage, let clip = step.gif, canvas.mode != .crop else {
            transport.isHidden = true
            return
        }
        transport.isHidden = false
        let active = step.isGIF
        let duration = step.clipData?.duration ?? clip.trimEnd
        scrubber.minValue = clip.trimStart
        scrubber.maxValue = max(clip.trimEnd, clip.trimStart + 0.01)
        scrubber.isEnabled = active
        playButton.isEnabled = active
        trimBar.duration = duration
        trimBar.trimStart = clip.trimStart
        trimBar.trimEnd = clip.trimEnd
        trimBar.clickTimes = step.clipData?.clicks.map(\.time) ?? []
        trimBar.isActive = active
        trimLabel.stringValue = Self.seconds(clip.length) + " kept"
        useStillButton.isEnabled = active
        revertStillButton.isEnabled = step.originalImageName != nil
        updateTimeReadout()
        updatePlayButton()
    }

    private func updateTimeReadout() {
        guard let step = currentStep, let clip = step.gif else { return }
        let duration = step.clipData?.duration ?? clip.trimEnd
        scrubber.doubleValue = playTime
        trimBar.playhead = playTime
        timeLabel.stringValue = step.isGIF
            ? "\(Self.clock(playTime)) / \(Self.clock(duration))"
            : "Showing the screenshot"
    }

    private func updatePlayButton() {
        let playing = playTimer != nil
        playButton.image = NSImage(systemSymbolName: playing ? "pause.circle.fill" : "play.circle.fill",
                                   accessibilityDescription: playing ? "Pause" : "Play")
        playButton.contentTintColor = playButton.isEnabled ? .controlAccentColor : .tertiaryLabelColor
    }

    private func updateInspector() {
        guard let step = currentStep else { showEmptyState(); return }
        inspectorStack.isHidden = false
        inspectorEmpty.isHidden = true

        contextLabel.stringValue = step.contextLine.isEmpty
            ? "Recorded without window details." : step.contextLine

        mediaControl.selectedSegment = step.isGIF ? 1 : 0
        mediaControl.setEnabled(step.hasFootage, forSegment: 1)
        mediaControl.setToolTip("Use the still screenshot in exports", forSegment: 0)
        mediaControl.setToolTip(step.hasFootage
            ? "Export the recorded clip as an animated GIF"
            : "This step has no footage. Hold Fn while clicking during a recording to capture a GIF.",
            forSegment: 1)
        if let clip = step.gif, let data = step.clipData {
            clipInfo.stringValue = "\(Self.seconds(data.duration)) clip · \(data.frames.count) frames · "
                + "plays \(Self.clock(clip.trimStart))–\(Self.clock(clip.trimEnd))"
        } else if step.gif != nil {
            clipInfo.stringValue = "The footage for this step could not be read."
        } else {
            clipInfo.stringValue = "Screenshot only. Hold Fn while you click during a recording "
                + "to capture a GIF for a step."
        }
        pointerToggle.isEnabled = step.hasFootage
        pointerToggle.state = (step.gif?.showPointer ?? false) ? .on : .off

        resetCropButton.isEnabled = step.crop != nil
        cropButton.title = step.crop == nil ? "Crop…" : "Edit Crop…"
        switch step.spotlight?.mode {
        case nil: spotlightControl.selectedSegment = 0
        case .dim?: spotlightControl.selectedSegment = 1
        case .magnify?: spotlightControl.selectedSegment = 2
        }
        let zoom = Double(step.spotlight?.zoom ?? 2)
        zoomSlider.doubleValue = zoom
        zoomSlider.isEnabled = step.spotlight?.mode == .magnify
        zoomValue.stringValue = String(format: "%.1f×", zoom)
        zoomValue.textColor = zoomSlider.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        highlightToggle.state = step.showHighlight ? .on : .off
        browserChromeToggle.isHidden = step.pageRect == nil
        browserChromeToggle.state = step.hidesBrowserChrome ? .on : .off

        coversAllButton.isEnabled = !step.redactions.isEmpty && guide.count > 1
        permanentButton.isEnabled = guide.redactionCount > 0
        undoButton.isEnabled = step.annotationCount > 0
        clearButton.isEnabled = step.annotationCount > 0
    }

    private func updateCaption() {
        guard let step = currentStep, let row = currentRow else { caption.stringValue = ""; return }
        var extras: [String] = []
        if !step.redactions.isEmpty {
            extras.append("\(step.redactions.count) cover\(step.redactions.count == 1 ? "" : "s")")
        }
        if !step.markups.isEmpty {
            extras.append("\(step.markups.count) drawing\(step.markups.count == 1 ? "" : "s")")
        }
        if step.crop != nil { extras.append("cropped") }
        caption.stringValue = "Step \(row + 1) of \(guide.count)"
            + (step.isGIF ? " · GIF" : "")
            + (extras.isEmpty ? "" : " · " + extras.joined(separator: ", "))
        switch canvas.mode {
        case .draw:
            hint.stringValue = "Drag to draw · click anything you drew to remove it"
        case .crop:
            hint.stringValue = "Drag the frame or its handles · ↩ applies · esc cancels"
        case .spotlight:
            hint.stringValue = step.spotlight?.mode == .magnify
                ? "Drag an area to spotlight · drag the inset to move it"
                : "Drag an area to spotlight it"
        }
    }

    private func updateButtons() {
        let row = table.selectedRow
        upButton.isEnabled = row > 0
        downButton.isEnabled = row >= 0 && row < guide.count - 1
        deleteButton.isEnabled = row >= 0 && !guide.isEmpty
        previousButton.isEnabled = row > 0
        nextButton.isEnabled = row >= 0 && row < guide.count - 1
        gmailButton.isEnabled = !isBusy
        exportButton.isEnabled = !isBusy
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(seconds, 0)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    static func seconds(_ seconds: Double) -> String { String(format: "%.1f s", max(seconds, 0)) }

    // MARK: Keys

    /// Space, ↩ and esc for the canvas. Anything being typed — the step text,
    /// the title, a label on the picture — keeps its keys; a focused button
    /// keeps Space.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return false }
        let responder = window.firstResponder
        if responder is NSText { return false }
        if let control = responder as? NSControl, control !== table { return false }
        switch event.keyCode {
        case 49:                                   // space
            guard currentStep?.isGIF == true, canvas.mode != .crop else { return false }
            togglePlayback()
            return true
        case 36, 76:                               // return, enter
            guard canvas.mode == .crop else { return false }
            applyCrop()
            return true
        case 53:                                   // escape
            guard canvas.mode == .crop else { return false }
            cancelCrop()
            return true
        default:
            return false
        }
    }

    // MARK: Undo
    //
    // Edit ▸ Undo arrives through `EditorWindow.undo(_:)` — NSWindow answers
    // `undo:` itself, so the responder chain never reaches this controller on
    // its own. Text views keep their typing undo; this is the annotations'.

    /// What ⌘Z can take back, newest last. Annotations are also undoable
    /// straight from the model (by draw order), which covers drawings made
    /// before this window opened; the stack is what orders them against step
    /// deletions, which the model cannot undo on its own.
    enum UndoItem {
        case annotation(UUID)
        case deletion(GuideStep, Int)
    }
    private var undoStack: [(item: UndoItem, folder: URL)] = []

    private func pushUndo(_ item: UndoItem) {
        undoStack.append((item, guide.folder))
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    /// Entries from another guide (New Guide, or one opened from the
    /// library) must never be replayed into this one.
    private func pruneUndo() {
        undoStack.removeAll { $0.folder != guide.folder }
    }

    var canUndoAnnotation: Bool {
        guard canvas.mode != .crop else { return false }
        pruneUndo()
        return !undoStack.isEmpty || (currentStep?.annotationCount ?? 0) > 0
    }

    private var undoTitle: String {
        if case .deletion? = undoStack.last?.item { return "Undo Delete Step" }
        return "Undo Drawing"
    }

    @objc func undo(_ sender: Any?) {
        pruneUndo()
        while let entry = undoStack.popLast() {
            switch entry.item {
            case .deletion(let step, let index):
                guard !guide.steps.contains(where: { $0.id == step.id }) else { continue }
                guide.insert(step, at: index)
                select(min(index, guide.count - 1))
                report("Restored step \(min(index, guide.count - 1) + 1).")
                return
            case .annotation(let id):
                guard let row = guide.steps.firstIndex(where: { $0.id == id }),
                      guide.steps[row].annotationCount > 0 else { continue }
                if row != currentRow { select(row) }
                guide.undoLastAnnotation(at: row)
                return
            }
        }
        undoAnnotation()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            let can = canUndoAnnotation
            menuItem.title = can ? undoTitle : "Undo"
            return can
        }
        return true
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return canUndoAnnotation }
        return true
    }

    // MARK: Tools

    @objc private func previousStep() { step(by: -1) }
    @objc private func nextStep() { step(by: 1) }

    private func step(by delta: Int) {
        let row = table.selectedRow + delta
        guard guide.steps.indices.contains(row) else { return }
        commitNote()
        select(row)
    }

    @objc private func toolChanged() {
        let index = min(max(toolControl.selectedSegment, 0), CanvasTool.all.count - 1)
        lastDrawTool = index
        if canvas.mode == .crop { endCrop(apply: false) }
        modeControl.selectedSegment = -1
        canvas.mode = .draw
        canvas.tool = CanvasTool.all[index]
        updateSwatches()
        updateCaption()
    }

    @objc private func modeChanged() {
        switch modeControl.selectedSegment {
        case 0:
            beginCrop()
        case 1:
            if canvas.mode == .crop { endCrop(apply: false) }
            toolControl.selectedSegment = -1
            modeControl.selectedSegment = 1
            canvas.mode = .spotlight
            if currentStep?.spotlight == nil {
                report("Drag across the picture to choose what to spotlight.")
            }
        default:
            break
        }
        updateSwatches()
        updateCaption()
    }

    /// Back to the drawing tool that was in use before crop or spotlight.
    private func returnToDrawing() {
        modeControl.selectedSegment = -1
        toolControl.selectedSegment = lastDrawTool
        canvas.mode = .draw
        canvas.tool = CanvasTool.all[lastDrawTool]
        updateSwatches()
    }

    private func colorPicked(_ colour: MarkupColor) {
        if canvas.tool == .cover {
            canvas.coverColor = colour
        } else {
            canvas.color = colour
        }
        updateSwatches()
    }

    /// One row of swatches serves two colours: the cover's and the drawing
    /// tools'. Each keeps its own, so switching from Cover to Arrow does not
    /// turn the next arrow black. The row rings the colour the active tool will
    /// use, and greys out when that tool is a mosaic (nothing to pick) or when
    /// cropping or spotlighting, which draw nothing.
    private func updateSwatches() {
        let isCover = canvas.tool == .cover
        let current = isCover ? canvas.coverColor : canvas.color
        let usable = canvas.mode == .draw && !(isCover && canvas.redactionStyle == .pixelate)
        for view in swatches {
            view.isChosen = view.swatch == current
            view.isUsable = usable
            view.toolTip = isCover ? "Cover colour: \(view.swatch.rawValue.capitalized)"
                                   : view.swatch.rawValue.capitalized
        }
    }

    @objc private func styleChanged() {
        canvas.redactionStyle = selectedStyle
        updateSwatches()
    }

    private var selectedStyle: RedactionStyle {
        stylePicker.indexOfSelectedItem == 1 ? .pixelate : .solid
    }

    // MARK: Crop

    @objc private func beginCropFromInspector() { beginCrop() }

    /// Crop mode: the uncropped picture, the current crop as a frame to
    /// drag. Playback stops — the frame is edited against the still.
    func beginCrop() {
        guard let step = currentStep else { return }
        pause()
        commitNote()
        canvas.commitText()
        toolControl.selectedSegment = -1
        modeControl.selectedSegment = 0
        canvas.mode = .crop
        aspectControl.selectedSegment = 0
        canvas.cropAspect = nil
        renderCanvas()           // uncropped, before the selection is measured
        canvas.cropSelection = step.crop ?? MarkupCanvas.whole
        drawStrip.isHidden = true
        cropStrip.isHidden = false
        transport.isHidden = true
        updateSwatches()
        updateCaption()
        window?.makeFirstResponder(canvas)
    }

    @objc func applyCrop() { endCrop(apply: true) }
    @objc private func cancelCrop() { endCrop(apply: false) }

    @objc private func resetCropSelection() {
        canvas.cropAspect = nil
        aspectControl.selectedSegment = 0
        canvas.cropSelection = MarkupCanvas.whole
    }

    @objc private func aspectChanged() {
        let i = min(max(aspectControl.selectedSegment, 0), Self.aspects.count - 1)
        canvas.cropAspect = Self.aspects[i].1
    }

    private func endCrop(apply: Bool, render: Bool = true) {
        guard canvas.mode == .crop else { return }
        let selection = canvas.cropSelection
        cropStrip.isHidden = true
        drawStrip.isHidden = false
        returnToDrawing()
        if apply, let row = currentRow {
            // `setCrop` treats a whole-picture selection as "no crop".
            guide.setCrop(selection, at: row)
            report(guide.steps[row].crop == nil ? "Showing the whole picture."
                                                : "Cropped step \(row + 1).")
        }
        if render {
            renderCanvas()
            updateTransport()
            updateCaption()
            window?.makeFirstResponder(table)
        }
    }

    @objc private func resetCrop() {
        guard let row = currentRow else { return }
        guide.setCrop(nil, at: row)
    }

    // MARK: Spotlight

    @objc private func spotlightChanged() {
        guard let step = currentStep, let row = currentRow else { return }
        switch spotlightControl.selectedSegment {
        case 1, 2:
            var spotlight = step.spotlight ?? Spotlight(rect: defaultSpotlightArea(for: step), mode: .dim)
            spotlight.mode = spotlightControl.selectedSegment == 2 ? .magnify : .dim
            spotlight.zoom = CGFloat(zoomSlider.doubleValue)
            guide.setSpotlight(spotlight, at: row)
            if canvas.mode != .spotlight {
                if canvas.mode == .crop { endCrop(apply: false) }
                toolControl.selectedSegment = -1
                modeControl.selectedSegment = 1
                canvas.mode = .spotlight
                updateSwatches()
                updateCaption()
            }
        default:
            guide.setSpotlight(nil, at: row)
        }
    }

    /// Around the clicked control when there is a box for it, otherwise a
    /// square around the click — a sensible first guess you then drag to fix.
    private func defaultSpotlightArea(for step: GuideStep) -> CGRect {
        let base: CGRect
        if let target = step.target, Annotator.isUsable(target, containing: step.click) {
            base = target.insetBy(dx: -max(target.width * 0.35, 0.03), dy: -max(target.height * 0.6, 0.03))
        } else {
            base = CGRect(x: step.click.x - 0.14, y: step.click.y - 0.14, width: 0.28, height: 0.28)
        }
        return base.intersection(MarkupCanvas.whole)
    }

    @objc private func zoomChanged() {
        guard let step = currentStep, let row = currentRow, var spotlight = step.spotlight else { return }
        spotlight.zoom = CGFloat(zoomSlider.doubleValue)
        guide.setSpotlight(spotlight, at: row)
    }

    private func spotlightAreaDrawn(_ rect: CGRect) {
        guard let step = currentStep, let row = currentRow,
              rect.width > 0.01, rect.height > 0.01 else { return }
        var spotlight = step.spotlight ?? Spotlight(rect: rect, mode: .dim)
        spotlight.rect = rect
        // A new area invalidates a hand-placed inset — it was placed for the
        // old one, and would now possibly sit on top of the new area.
        spotlight.inset = nil
        guide.setSpotlight(spotlight, at: row)
    }

    private func magnifierMoved(to point: CGPoint) {
        guard let step = currentStep, let row = currentRow, var spotlight = step.spotlight else { return }
        spotlight.inset = point
        guide.setSpotlight(spotlight, at: row)
    }

    // MARK: Media

    @objc func mediaChanged(_ sender: NSSegmentedControl) {
        guard let row = currentRow else { return }
        let wanted: StepMedia = sender.selectedSegment == 1 ? .gif : .screenshot
        if !guide.setMedia(wanted, at: row) {
            sender.selectedSegment = 0
            report("This step has no footage to play.")
        }
    }

    @objc private func togglePointer() {
        guard let row = currentRow else { return }
        guide.setShowPointer(pointerToggle.state == .on, at: row)
    }

    @objc private func toggleBrowserChrome() {
        guard let row = currentRow else { return }
        guide.setHidesBrowserChrome(browserChromeToggle.state == .on, at: row)
    }

    @objc private func toggleAutoHighlight() {
        guard let row = currentRow else { return }
        guide.setShowHighlight(highlightToggle.state == .on, at: row)
    }

    // MARK: Replace image

    @objc private func replaceFromFile() {
        guard let window, let step = currentStep else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for this step. Its text stays the same."
        panel.prompt = "Use Picture"
        let id = step.id
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let image = Self.readImage(at: url) else {
                    self.report("Could not read \(url.lastPathComponent) as a picture.")
                    return
                }
                // The open panel is still closing; a second sheet has to wait
                // for it to be gone or it will not appear.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.confirmReplace(with: image, stepID: id) }
                }
            }
        }
    }

    @objc private func replaceFromClipboard() {
        guard let step = currentStep else { return }
        guard let image = Self.clipboardImage() else {
            report("The clipboard has no picture. Copy a screenshot first (⌃⇧⌘4).")
            return
        }
        confirmReplace(with: image, stepID: step.id)
    }

    /// Replacing clears everything drawn for the old picture — covers
    /// included — so it asks first when there is anything to lose.
    private func confirmReplace(with image: CGImage, stepID: UUID) {
        guard let window, let row = guide.steps.firstIndex(where: { $0.id == stepID }) else { return }
        let step = guide.steps[row]
        var losing: [String] = []
        if step.hasFootage { losing.append("its GIF footage") }
        if !step.redactions.isEmpty { losing.append("covers") }
        if !step.markups.isEmpty { losing.append("drawings") }
        if step.crop != nil { losing.append("the crop") }
        if step.spotlight != nil { losing.append("the spotlight") }
        guard !losing.isEmpty else { replace(with: image, stepID: stepID); return }

        let alert = NSAlert()
        alert.messageText = "Replace the picture for step \(row + 1)?"
        let list = losing.count == 1 ? losing[0]
            : losing.dropLast().joined(separator: ", ") + " and " + losing.last!
        alert.informativeText = "The step keeps its text, but \(list) will be removed — they "
            + "were placed for the old picture and would not line up with the new one. "
            + "The old files stay in the guide folder."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.replace(with: image, stepID: stepID) }
        }
    }

    private func replace(with image: CGImage, stepID: UUID) {
        guard let row = guide.steps.firstIndex(where: { $0.id == stepID }) else { return }
        pause()
        if guide.replaceImage(image, at: row) {
            report("Replaced the picture for step \(row + 1).")
        } else {
            report("Could not save the new picture.")
        }
    }

    static func readImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// PNG or TIFF data first — a screenshot on the clipboard is one of those,
    /// and decoding the data keeps full resolution where NSImage may pick a
    /// smaller representation.
    static func clipboardImage() -> CGImage? {
        let board = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return image
            }
        }
        if let image = (board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
    }

    // MARK: Annotations

    private func addRedaction(_ rect: CGRect, color: MarkupColor) {
        guard let row = currentRow else { return }
        let before = guide.steps[row].annotationCount
        guide.addRedaction(Redaction(rect: rect, style: selectedStyle, color: color), at: row)
        if guide.steps[row].annotationCount > before { pushUndo(.annotation(guide.steps[row].id)) }
    }

    private func addMarkup(_ markup: Markup) {
        guard let row = currentRow else { return }
        let before = guide.steps[row].annotationCount
        guide.addMarkup(markup, at: row)
        if guide.steps[row].annotationCount > before { pushUndo(.annotation(guide.steps[row].id)) }
    }

    private func removeAnnotation(at point: CGPoint) {
        guard let row = currentRow else { return }
        guide.removeAnnotation(at: row, containing: point)
    }

    @objc private func undoAnnotation() {
        guard let row = currentRow else { return }
        guide.undoLastAnnotation(at: row)
    }

    @objc private func clearAnnotations() {
        guard let row = currentRow else { return }
        guide.clearAnnotations(at: row)
    }

    @objc private func applyRedactionsEverywhere() {
        guard let row = currentRow else { return }
        let touched = guide.applyRedactionsEverywhere(from: row)
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
                self.report("Wrote covers into \(done) screenshot\(done == 1 ? "" : "s").")
            }
        }
    }

    // MARK: Step actions

    @objc private func moveStepUp()   { move(by: -1) }
    @objc private func moveStepDown() { move(by:  1) }

    private func move(by delta: Int) {
        guard let row = currentRow else { return }
        commitNote()
        let landed = guide.move(from: row, by: delta)
        select(landed)
    }

    @objc private func deleteStep() {
        guard let row = currentRow else { return }
        commitNote()
        let step = guide.steps[row]
        guide.remove(at: row)
        // Backspace in the list deletes, and a stray Backspace is easy; ⌘Z has
        // to bring the step back or that key is a data-loss shortcut.
        pushUndo(.deletion(step, row))
        report("Deleted step \(row + 1). ⌘Z brings it back.")
        // `refresh` (via the notification) already handed the selection to
        // the neighbour; this keeps it there even if the list was reloaded
        // some other way.
        select(min(row, guide.count - 1))
    }

    /// No confirmation sheet: starting a new guide throws nothing away. The old
    /// one keeps its folder and shows up in the library a moment later. The
    /// previous version asked "Erase this guide?" and then did not erase it,
    /// which is a worse kind of wrong than not asking.
    @objc func newGuide() {
        commitNote()
        onNewGuide?()
    }

    // MARK: Export
    //
    // GIF steps take seconds to encode, so every exporter is awaited off the
    // main thread and the status says so meanwhile. The buttons stay disabled
    // until it finishes — a second export started over the first would race
    // it for the same files.

    private var busyMessage: String {
        guide.steps.contains { $0.isGIF } ? "Rendering GIFs…" : "Exporting…"
    }

    private func beginBusy(_ message: String? = nil) {
        isBusy = true
        statusLabel.stringValue = message ?? busyMessage
        updateButtons()
    }

    private func endBusy() {
        isBusy = false
        updateButtons()
    }

    @objc private func copyForGmail() {
        guard !guide.isEmpty else { report("Nothing to copy yet."); return }
        guard !isBusy else { return }
        commitNote()
        beginBusy()
        Task { @MainActor in
            let bytes = await Export.copyForEmailAsync(self.guide)
            self.endBusy()
            let mb = Double(bytes) / 1_048_576
            self.report(String(format: "Copied %d step%@ (%.1f MB). Paste into Gmail with ⌘V.",
                               self.guide.count, self.guide.count == 1 ? "" : "s", mb))
        }
    }

    @objc private func exportEmailHTML() {
        save(name: "\(guide.title) (email).html", type: .html) { url in
            let html = await Export.emailHTMLAsync(self.guide)
            try html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func exportHTML() {
        save(name: "\(guide.title).html", type: .html) { url in
            let html = await Export.htmlAsync(self.guide)
            try html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func exportMarkdown() {
        guard let window, !isBusy else { return }
        commitNote()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = guide.title
        panel.message = "Choose where to create the guide folder."
        panel.prompt = "Create"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.beginBusy()
                Task { @MainActor in
                    do {
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        try await Export.markdownAsync(self.guide, to: url)
                        self.endBusy()
                        self.finishExport(at: url)
                    } catch {
                        self.endBusy()
                        self.report("Markdown export failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @objc private func exportPDF() {
        guard let window, !isBusy else { return }
        commitNote()
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
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let density = Export.PageDensity.choices[
                    min(max(picker.indexOfSelectedItem, 0), Export.PageDensity.choices.count - 1)]
                Settings.shared.pdfDensity = density
                self.beginBusy("Rendering PDF (\(density.label))…")
                Task { @MainActor in
                    let strips = await Export.prepareFilmstrips(self.guide)
                    Export.pdf(self.guide, to: url, density: density, strips: strips) { error in
                        // Hop explicitly: the completion may arrive off the main
                        // thread once GIF filmstrips render in the background.
                        let failure = error?.localizedDescription
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.endBusy()
                                if let failure {
                                    self.report("PDF export failed: \(failure)")
                                } else {
                                    self.finishExport(at: url)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A save panel as a sheet, then the (async) write, then Show in Finder.
    private func save(name: String, type: UTType,
                      write: @escaping @MainActor (URL) async throws -> Void) {
        guard let window, !isBusy else { return }
        commitNote()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.beginBusy()
                Task { @MainActor in
                    do {
                        try await write(url)
                        self.endBusy()
                        self.finishExport(at: url)
                    } catch {
                        self.endBusy()
                        self.report("Export failed: \(error.localizedDescription)")
                    }
                }
            }
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
