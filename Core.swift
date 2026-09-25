//
//  Scribe — model, geometry, images, annotation
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
// MARK: - Diagnostics
//
// Writes scribe.log next to the .app bundle. Unified logging redacts too much
// and is awkward to read back; a plain file next to the project is not.
// ─────────────────────────────────────────────────────────────────────────────

enum Diag {
    private static let url: URL = {
        URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
            .appendingPathComponent("scribe.log")
    }()

    private static let queue = DispatchQueue(label: "com.ethantruslow.scribe.diag")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    nonisolated(unsafe) private static var seen = Set<String>()

    static func start() {
        queue.async {
            let header = "===== Scribe log started \(Date()) =====\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func log(_ message: String) {
        NSLog("Scribe: %@", message)
        queue.async {
            let line = "[\(stamp.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Logs the first time only, for per-frame paths that would otherwise
    /// produce a megabyte of identical lines.
    static func once(_ key: String, _ message: String) {
        var fire = false
        queue.sync {
            if !seen.contains(key) { seen.insert(key); fire = true }
        }
        if fire { log(message) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Geometry helpers
//
// Three coordinate systems meet in this app and mixing them up is the single
// easiest way to put the highlight box in the wrong place:
//
//   NSEvent / NSScreen  bottom-left origin, y up, points, global
//   Accessibility API   top-left origin,    y down, points, global
//   CGImage / CGContext pixels; CGContext draws bottom-left origin
//
// Everything the model stores is NORMALISED to its screen: 0…1, top-left
// origin. That survives downscaling the screenshot, Retina vs non-Retina, and
// a second display at a different size, none of which a pixel value does.
// ─────────────────────────────────────────────────────────────────────────────

enum Geo {
    /// The screen a global (NSEvent) point falls on.
    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// The top edge of the primary display in NSScreen coordinates. This is the
    /// hinge the Accessibility API's flipped y-axis pivots around.
    static var primaryTop: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// The whole of a screen, expressed the way every region here is: points,
    /// screen-local, top-left origin.
    static func fullRegion(of screen: NSScreen) -> CGRect {
        CGRect(origin: .zero, size: screen.frame.size)
    }

    /// Global NSScreen point → screen-local points, top-left origin.
    static func localPoint(_ point: CGPoint, on screen: NSScreen) -> CGPoint {
        CGPoint(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y)
    }

    /// Accessibility rect (global, top-left origin, y down) → screen-local
    /// points, top-left origin. The AX flip pivots around the *primary*
    /// display's top edge, not this screen's.
    static func localRect(axRect: CGRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        let nsMaxY = primaryTop - axRect.minY          // AX y-down → NS y-up
        return CGRect(x: axRect.minX - f.minX,
                      y: f.maxY - nsMaxY,
                      width: axRect.width,
                      height: axRect.height)
    }

    /// Screen-local point → 0…1 within `region`, top-left origin.
    ///
    /// Everything the model stores is normalised against the *captured region*,
    /// not the screen. When the capture is cropped to one window, the screenshot
    /// starts at that window's corner, and a fraction measured against the whole
    /// display would put the highlight somewhere else entirely.
    static func normalize(localPoint p: CGPoint, in region: CGRect) -> CGPoint {
        guard region.width > 0, region.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (p.x - region.minX) / region.width,
                       y: (p.y - region.minY) / region.height)
    }

    /// Screen-local rect → 0…1 within `region`, top-left origin.
    static func normalize(localRect r: CGRect, in region: CGRect) -> CGRect {
        guard region.width > 0, region.height > 0 else { return .zero }
        return CGRect(x: (r.minX - region.minX) / region.width,
                      y: (r.minY - region.minY) / region.height,
                      width: r.width / region.width,
                      height: r.height / region.height)
    }

    /// Clamps a region to the screen and refuses slivers, so a stale or
    /// offscreen window frame falls back to the whole display rather than
    /// producing a two-pixel-wide screenshot.
    static func sanitize(region: CGRect, on screen: NSScreen) -> CGRect? {
        let full = fullRegion(of: screen)
        let clipped = region.intersection(full)
        guard clipped.width >= 120, clipped.height >= 90 else { return nil }
        return clipped
    }

    /// A normalised (top-left origin) rect → CGContext drawing rect for an
    /// image `w`×`h` pixels. CGContext is bottom-left origin, hence the flip.
    static func drawRect(_ norm: CGRect, in w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: norm.minX * w,
               y: h - (norm.minY * h) - (norm.height * h),
               width: norm.width * w,
               height: norm.height * h)
    }

    /// A normalised (top-left origin) point → CGContext drawing point.
    static func drawPoint(_ norm: CGPoint, in w: CGFloat, _ h: CGFloat) -> CGPoint {
        CGPoint(x: norm.x * w, y: h - (norm.y * h))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Capture scope
//
// What ends up in the screenshot. A full-desktop shot of a browser tutorial is
// mostly wallpaper, dock and menu bar — the reader has to hunt for the part
// that matters. Cropping to the window turns the same recording into something
// that looks deliberate.
//
// The crop is computed from the Accessibility window frame at click time, not
// from the capture filter: ScreenCaptureKit streams whole displays here (see
// `Capture`), and cropping a CGImage is nearly free because it shares the
// original's backing store.
// ─────────────────────────────────────────────────────────────────────────────

enum CaptureScope: Equatable {
    /// Everything on the display the click happened on.
    case wholeScreen
    /// The window the click landed in, whatever app that is. The usual choice.
    case clickedWindow
    /// Only one app: clicks anywhere else are ignored entirely, and the shot is
    /// cropped to that app's window. For a guide about one tool.
    case app(bundleID: String, name: String)

    var label: String {
        switch self {
        case .wholeScreen:      return "Whole Screen"
        case .clickedWindow:    return "Window You Click In"
        case .app(_, let name): return name
        }
    }

    var storageValue: String {
        switch self {
        case .wholeScreen:            return "screen"
        case .clickedWindow:          return "window"
        case .app(let id, let name):  return "app:\(id)|\(name)"
        }
    }

    static func from(storage: String?) -> CaptureScope {
        guard let storage else { return .clickedWindow }
        if storage == "screen" { return .wholeScreen }
        if storage == "window" { return .clickedWindow }
        if storage.hasPrefix("app:") {
            let body = String(storage.dropFirst(4))
            let parts = body.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { return .app(bundleID: parts[0], name: parts[1]) }
        }
        return .clickedWindow
    }
}

@MainActor
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// Cropping to the clicked window is the default because it is what makes
    /// the output look like a guide rather than a screen recording.
    var captureScope: CaptureScope {
        get { CaptureScope.from(storage: defaults.string(forKey: "captureScope")) }
        set { defaults.set(newValue.storageValue, forKey: "captureScope") }
    }

    /// Branding applied to exported guides.
    var exportTheme: ExportTheme {
        get { ExportTheme.with(id: defaults.string(forKey: "exportTheme") ?? "scribe") }
        set { defaults.set(newValue.id, forKey: "exportTheme") }
    }

    /// Whether starting a recording on an empty guide asks for a name first.
    var askForGuideName: Bool {
        get { defaults.object(forKey: "askForGuideName") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "askForGuideName") }
    }

    /// Steps per page for PDF export. Remembered, because whoever wants one
    /// step per page for printing usually wants that every time.
    var pdfDensity: Export.PageDensity {
        get { Export.PageDensity.from(storage: defaults.integer(forKey: "pdfDensity")) }
        set { defaults.set(newValue.storageValue, forKey: "pdfDensity") }
    }

    /// Apps worth offering in the capture menu: things with a Dock presence and
    /// at least one real window, most recently used first. Everything else is
    /// daemons and agents nobody is writing a tutorial about.
    static func commonApps() -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName
                else { return nil }
                return (id, name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image utilities
// ─────────────────────────────────────────────────────────────────────────────

enum Img {
    /// Longest edge of a stored screenshot. A full Retina display frame is
    /// ~30 MB uncompressed; a 40-step guide of those is a gigabyte of RAM. The
    /// screenshots go to disk downscaled and only thumbnails stay resident.
    static let maxEdge: CGFloat = 1800

    static func downscale(_ image: CGImage, maxEdge: CGFloat = Img.maxEdge) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let longest = max(w, h)
        guard longest > maxEdge else { return image }
        let scale = maxEdge / longest
        return redraw(image, to: CGSize(width: (w * scale).rounded(),
                                        height: (h * scale).rounded())) ?? image
    }

    static func redraw(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard size.width >= 1, size.height >= 1,
              let ctx = CGContext(data: nil,
                                  width: Int(size.width),
                                  height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// Crops a whole-display frame down to `region`, which is in points,
    /// top-left origin, relative to a display of `fullSize` points.
    ///
    /// Cheap — a cropped CGImage shares the original's backing store. CGImage
    /// cropping is already top-left origin, the same convention every region in
    /// this file uses, so there is no flip here and there must not be one.
    static func crop(_ image: CGImage, to region: CGRect, fullSize: CGSize) -> CGImage? {
        guard fullSize.width > 0, fullSize.height > 0 else { return image }
        guard region != CGRect(origin: .zero, size: fullSize) else { return image }

        let sx = CGFloat(image.width) / fullSize.width
        let sy = CGFloat(image.height) / fullSize.height
        let pixels = CGRect(x: (region.minX * sx).rounded(.down),
                            y: (region.minY * sy).rounded(.down),
                            width: (region.width * sx).rounded(),
                            height: (region.height * sy).rounded())
        return image.cropping(to: pixels) ?? image
    }

    /// Mean brightness of a region, 0…1. Cropping to one pixel is the cheapest
    /// possible average and exactly as accurate as one.
    static func averageLuminance(of image: CGImage, in norm: CGRect) -> CGFloat? {
        let pixels = CGRect(x: norm.minX * CGFloat(image.width),
                            y: norm.minY * CGFloat(image.height),
                            width: max(norm.width * CGFloat(image.width), 1),
                            height: max(norm.height * CGFloat(image.height), 1)).integral
        guard let piece = image.cropping(to: pixels),
              let one = redraw(piece, to: CGSize(width: 1, height: 1)),
              let rgb = sample(one, at: CGPoint(x: 0.5, y: 0.5))
        else { return nil }
        return (0.299 * CGFloat(rgb.r) + 0.587 * CGFloat(rgb.g) + 0.114 * CGFloat(rgb.b)) / 255
    }

    /// The colour at a normalised point, top-left origin. Used by the self-test
    /// to prove a redaction actually replaced pixels rather than merely being
    /// drawn over them somewhere downstream.
    static func sample(_ image: CGImage, at norm: CGPoint) -> (r: Int, g: Int, b: Int)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let x = norm.x * CGFloat(image.width)
        let y = norm.y * CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: -x, y: y - CGFloat(image.height),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func readPNG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// JPEG, for the email export only. A 10-step guide of PNG screenshots is
    /// 15 MB of base64 in the message body, which Gmail will not thank you for;
    /// the same guide as quality-0.8 JPEG is closer to 1 MB.
    static func jpegData(_ image: CGImage, quality: CGFloat = 0.8) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Redaction
//
// Covering up a student name, an email address, a grade. Stored as normalised
// rects on the step, exactly like the highlight target, so a redaction survives
// the screenshot being downscaled or re-rendered at a different size.
//
// Applied inside `GuideStep.annotated`, which every export and every thumbnail
// already goes through — so there is no path that renders a step and forgets to
// redact it. That is the whole reason it lives there rather than in each
// exporter.
// ─────────────────────────────────────────────────────────────────────────────

enum RedactionStyle: String {
    /// A coarse mosaic — block size is 1/90 of the longest edge, minimum 14 px,
    /// which destroys UI-sized text. Reads as "a name was here", which is often
    /// what a tutorial wants.
    ///
    /// It is a *presentation* choice, not a security one: shape, colour and
    /// layout survive it, and pixelation of known-format text has been undone
    /// before. Anything that would actually matter if recovered gets `.solid`.
    case pixelate
    /// A flat bar. Nothing survives it and nothing is implied about what was
    /// underneath. The default, and the right answer whenever there is doubt.
    case solid

    var label: String { self == .pixelate ? "Pixelate" : "Solid bar" }
}

struct Redaction: Equatable {
    /// 0…1, top-left origin, against the captured region — same space as
    /// `GuideStep.click` and `.target`.
    var rect: CGRect
    var style: RedactionStyle
    /// Fill for a `.solid` bar; a mosaic ignores it. Guides saved before covers
    /// had a colour have no key and load as black, which is what they were.
    var color: MarkupColor = .black
    /// Draw order across covers *and* markup, so one Undo can pop whichever of
    /// the two was actually added last.
    var seq: Int = 0

    var dictionary: [String: Any] {
        ["x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height,
         "style": style.rawValue, "color": color.rawValue, "seq": seq]
    }

    static func from(_ d: [String: Any]) -> Redaction? {
        guard let x = d["x"] as? CGFloat, let y = d["y"] as? CGFloat,
              let w = d["w"] as? CGFloat, let h = d["h"] as? CGFloat
        else { return nil }
        return Redaction(rect: CGRect(x: x, y: y, width: w, height: h),
                         style: RedactionStyle(rawValue: d["style"] as? String ?? "") ?? .solid,
                         color: MarkupColor(rawValue: d["color"] as? String ?? "") ?? .black,
                         seq: d["seq"] as? Int ?? 0)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Markup
//
// Drawing on a screenshot: arrows, outlines, freehand, highlighter, text.
// Everything is normalised 0…1 top-left, exactly like `Redaction` and
// `GuideStep.target`, so a drawing survives the screenshot being downscaled or
// exported at a different size.
//
// Stroke widths are stored as a fraction of the image's longest edge for the
// same reason — a 3 px line on a 3456 px capture is invisible in a PDF.
// ─────────────────────────────────────────────────────────────────────────────

enum MarkupKind: String {
    case arrow, line, box, ellipse, pen, highlighter, text

    /// Whether the tool is defined by two corners (drag) or a stream of points.
    var isFreehand: Bool { self == .pen || self == .highlighter }

    /// Fraction of the longest edge. The highlighter is fat on purpose — it is
    /// meant to wash over a word, not underline it.
    var defaultWidth: CGFloat {
        switch self {
        case .highlighter: return 0.022
        case .pen:         return 0.0035
        default:           return 0.004
        }
    }

    var label: String {
        switch self {
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .box: return "Box"
        case .ellipse: return "Circle"
        case .pen: return "Pen"
        case .highlighter: return "Marker"
        case .text: return "Text"
        }
    }
}

enum MarkupColor: String, CaseIterable {
    case red, orange, yellow, green, blue, white, black

    var cgColor: CGColor {
        switch self {
        case .red:    return CGColor(red: 0.94, green: 0.16, blue: 0.35, alpha: 1)
        case .orange: return CGColor(red: 1.00, green: 0.55, blue: 0.10, alpha: 1)
        case .yellow: return CGColor(red: 1.00, green: 0.84, blue: 0.15, alpha: 1)
        case .green:  return CGColor(red: 0.16, green: 0.74, blue: 0.42, alpha: 1)
        case .blue:   return CGColor(red: 0.16, green: 0.51, blue: 0.96, alpha: 1)
        case .white:  return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .black:  return CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)
        }
    }

    var nsColor: NSColor { NSColor(cgColor: cgColor) ?? .systemRed }
}

struct Markup: Equatable {
    var kind: MarkupKind
    /// Normalised, top-left origin. Two points for the drag tools (start, end);
    /// one for text; many for freehand.
    var points: [CGPoint]
    var color: MarkupColor
    /// Fraction of the longest edge.
    var width: CGFloat
    /// Only for `.text`; also normalised so it scales with the image.
    var text: String = ""
    var fontSize: CGFloat = 0.030
    var seq: Int = 0

    /// Bounding box, used for hit-testing a click that means "remove this".
    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        var box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if kind == .text {
            // A text anchor is a single point; give it a plausible box so it
            // can be clicked away again.
            box = CGRect(x: minX, y: minY - fontSize * 0.2,
                         width: Swift.max(CGFloat(text.count) * fontSize * 0.5, 0.04),
                         height: fontSize * 1.3)
        }
        return box.insetBy(dx: -0.008, dy: -0.008)
    }

    var dictionary: [String: Any] {
        ["kind": kind.rawValue,
         "points": points.flatMap { [$0.x, $0.y] },
         "color": color.rawValue,
         "width": width,
         "text": text,
         "fontSize": fontSize,
         "seq": seq]
    }

    static func from(_ d: [String: Any]) -> Markup? {
        guard let kind = MarkupKind(rawValue: d["kind"] as? String ?? ""),
              let flat = d["points"] as? [CGFloat], flat.count >= 2
        else { return nil }
        var points: [CGPoint] = []
        for i in stride(from: 0, to: flat.count - 1, by: 2) {
            points.append(CGPoint(x: flat[i], y: flat[i + 1]))
        }
        return Markup(kind: kind,
                      points: points,
                      color: MarkupColor(rawValue: d["color"] as? String ?? "") ?? .red,
                      width: d["width"] as? CGFloat ?? kind.defaultWidth,
                      text: d["text"] as? String ?? "",
                      fontSize: d["fontSize"] as? CGFloat ?? 0.030,
                      seq: d["seq"] as? Int ?? 0)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Annotation
//
// The highlight is the whole visual point of a Scribe-style guide: the reader
// should see where to click without reading a word. Two shapes, picked by what
// the Accessibility API could tell us:
//
//   a rounded box   when we know the control's frame and it looks sane
//   a ring          when we only know where the pointer was
//
// Both get a white outer stroke under the colour, because a red box on a red
// toolbar is invisible and every app has some toolbar the wrong colour.
// ─────────────────────────────────────────────────────────────────────────────

enum Annotator {
    static let accent = CGColor(red: 0.94, green: 0.16, blue: 0.35, alpha: 1.0)
    static let halo   = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)

    /// A target rect we should not trust. The Accessibility API happily returns
    /// the whole window (or the whole screen) when a click lands on a plain
    /// background, and boxing the entire screenshot tells the reader nothing.
    static func isUsable(_ rect: CGRect?, containing click: CGPoint) -> Bool {
        guard let r = rect else { return false }
        guard r.width > 0.004, r.height > 0.004 else { return false }   // sub-pixel junk
        guard r.width * r.height < 0.45 else { return false }           // "the whole window"
        guard r.width < 0.92, r.height < 0.92 else { return false }
        // A frame that does not contain the click is stale or from another space.
        return r.insetBy(dx: -0.01, dy: -0.01).contains(click)
    }

    /// Paints the redactions over a copy of the image.
    ///
    /// The mosaic is done by downscaling the region to a handful of pixels and
    /// drawing it back with interpolation off — no CoreImage, no filter chain,
    /// and the block size is an honest guarantee rather than a blur radius that
    /// might be unwound. Text does not survive a 14 px block.
    static func redact(_ image: CGImage, with redactions: [Redaction]) -> CGImage? {
        guard !redactions.isEmpty else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil,
                                  width: image.width,
                                  height: image.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        for redaction in redactions {
            let target = Geo.drawRect(redaction.rect, in: w, h).integral
            guard target.width >= 1, target.height >= 1 else { continue }

            switch redaction.style {
            case .solid:
                ctx.setFillColor(redaction.color.cgColor)
                ctx.fill(target)

            case .pixelate:
                // Crop → shrink → draw back with no interpolation.
                let block = max(CGFloat(14), max(w, h) / 90)
                let across = max(Int((target.width / block).rounded()), 1)
                let down = max(Int((target.height / block).rounded()), 1)
                guard let piece = image.cropping(to: target),
                      let tiny = Img.redraw(piece, to: CGSize(width: across, height: down))
                else {
                    ctx.setFillColor(CGColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1))
                    ctx.fill(target)
                    continue
                }
                ctx.saveGState()
                ctx.interpolationQuality = .none
                ctx.draw(tiny, in: target)
                ctx.restoreGState()
            }

            // A hairline so a redaction reads as deliberate rather than as a
            // rendering glitch.
            ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            ctx.setLineWidth(max(1, max(w, h) / 900))
            ctx.stroke(target)
        }
        return ctx.makeImage()
    }

    /// Paints markup over the image. Runs last, on top of the automatic
    /// highlight, so a hand-drawn arrow is never hidden behind it.
    static func draw(_ markups: [Markup], on image: CGImage) -> CGImage? {
        guard !markups.isEmpty else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil,
                                  width: image.width,
                                  height: image.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let longest = max(w, h)

        for markup in markups.sorted(by: { $0.seq < $1.seq }) {
            let points = markup.points.map { Geo.drawPoint($0, in: w, h) }
            guard let first = points.first else { continue }
            let stroke = max(markup.width * longest, 1)
            ctx.setStrokeColor(markup.color.cgColor)
            ctx.setFillColor(markup.color.cgColor)
            ctx.setLineWidth(stroke)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            switch markup.kind {
            case .line, .arrow:
                guard points.count >= 2 else { continue }
                let end = points[1]
                if markup.kind == .arrow {
                    drawArrow(from: first, to: end, stroke: stroke, in: ctx)
                } else {
                    ctx.move(to: first); ctx.addLine(to: end); ctx.strokePath()
                }

            case .box:
                guard points.count >= 2 else { continue }
                ctx.stroke(rect(first, points[1]))

            case .ellipse:
                guard points.count >= 2 else { continue }
                ctx.strokeEllipse(in: rect(first, points[1]))

            case .pen:
                ctx.move(to: first)
                for p in points.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()

            case .highlighter:
                // A real highlighter multiplies — which is right over a light UI
                // (the text underneath stays crisp) and useless over a dark one,
                // where yellow-times-near-black is a grey smudge. So the blend
                // mode follows the background: multiply over light, plain alpha
                // over dark, which is the closest thing to "a visible yellow
                // wash" that either case allows.
                let bright = Img.averageLuminance(of: image, in: markup.bounds) ?? 1
                ctx.saveGState()
                if bright > 0.5 {
                    ctx.setBlendMode(.multiply)
                    ctx.setAlpha(0.45)
                } else {
                    ctx.setBlendMode(.normal)
                    ctx.setAlpha(0.55)
                }
                ctx.setLineCap(.butt)
                ctx.move(to: first)
                for p in points.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
                ctx.restoreGState()

            case .text:
                drawLabel(markup, at: first, longest: longest, in: ctx)
            }
        }
        return ctx.makeImage()
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// A shaft that stops short of the tip, plus a filled head — drawing the
    /// full-length shaft leaves a spur poking out of the point of the arrow.
    private static func drawArrow(from a: CGPoint, to b: CGPoint,
                                  stroke: CGFloat, in ctx: CGContext) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = max(stroke * 3.4, 8)
        let shaftEnd = CGPoint(x: b.x - cos(angle) * head * 0.85,
                               y: b.y - sin(angle) * head * 0.85)
        ctx.move(to: a); ctx.addLine(to: shaftEnd); ctx.strokePath()

        let spread = CGFloat.pi / 7
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: b.x - cos(angle - spread) * head,
                                y: b.y - sin(angle - spread) * head))
        ctx.addLine(to: CGPoint(x: b.x - cos(angle + spread) * head,
                                y: b.y - sin(angle + spread) * head))
        ctx.closePath()
        ctx.fillPath()
    }

    /// Text gets a soft backing plate. A caption typed onto a screenshot lands
    /// on whatever colour happens to be there, and white-on-white is the
    /// default outcome without one.
    private static func drawLabel(_ markup: Markup, at point: CGPoint,
                                  longest: CGFloat, in ctx: CGContext) {
        guard !markup.text.isEmpty else { return }
        let size = max(markup.fontSize * longest, 8)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: markup.color.nsColor,
        ]
        let string = NSAttributedString(string: markup.text, attributes: attributes)
        let measured = string.size()
        let pad = size * 0.28
        let plate = CGRect(x: point.x - pad, y: point.y - measured.height - pad,
                           width: measured.width + pad * 2,
                           height: measured.height + pad * 2)

        let dark = markup.color == .white || markup.color == .yellow
        ctx.setFillColor(dark ? CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 0.72)
                              : CGColor(red: 1, green: 1, blue: 1, alpha: 0.86))
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: pad, cornerHeight: pad,
                           transform: nil))
        ctx.fillPath()

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        string.draw(at: CGPoint(x: point.x, y: point.y - measured.height))
        NSGraphicsContext.current = previous
    }

    /// Draws the highlight and the step number onto a copy of the screenshot.
    static func annotate(_ image: CGImage,
                         click: CGPoint,
                         target: CGRect?,
                         number: Int) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil,
                                  width: image.width,
                                  height: image.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Stroke widths scale with the image so a 1800 px and a 900 px export
        // look like the same drawing, not the same number of pixels.
        let unit = max(w, h) / 450.0
        ctx.setLineJoin(.round)

        var badgeAnchor: CGPoint

        if isUsable(target, containing: click), let t = target {
            let r = Geo.drawRect(t, in: w, h).insetBy(dx: -unit * 1.5, dy: -unit * 1.5)
            let path = CGPath(roundedRect: r,
                              cornerWidth: min(unit * 4, r.width / 2),
                              cornerHeight: min(unit * 4, r.height / 2),
                              transform: nil)
            ctx.setStrokeColor(halo)
            ctx.setLineWidth(unit * 4.5)
            ctx.addPath(path); ctx.strokePath()
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(unit * 2.2)
            ctx.addPath(path); ctx.strokePath()
            badgeAnchor = CGPoint(x: r.minX, y: r.maxY)
        } else {
            let c = Geo.drawPoint(click, in: w, h)
            let radius = unit * 13
            let ring = CGRect(x: c.x - radius, y: c.y - radius,
                              width: radius * 2, height: radius * 2)
            ctx.setStrokeColor(halo)
            ctx.setLineWidth(unit * 4.5)
            ctx.strokeEllipse(in: ring)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(unit * 2.2)
            ctx.strokeEllipse(in: ring)
            ctx.setFillColor(accent.copy(alpha: 0.18) ?? accent)
            ctx.fillEllipse(in: ring)
            // Out along the up-left diagonal by a full radius, so the badge
            // sits beside the ring rather than eating it.
            badgeAnchor = CGPoint(x: c.x - radius, y: c.y + radius)
        }

        drawBadge(number, at: badgeAnchor, unit: unit, in: ctx, imageW: w, imageH: h)
        return ctx.makeImage()
    }

    /// The numbered dot that sits on the corner of the highlight. Core Text via
    /// NSAttributedString, drawn through an NSGraphicsContext wrapping the same
    /// CGContext — cheaper to write than laying out a CTLine by hand.
    private static func drawBadge(_ number: Int,
                                  at anchor: CGPoint,
                                  unit: CGFloat,
                                  in ctx: CGContext,
                                  imageW: CGFloat,
                                  imageH: CGFloat) {
        let d = unit * 11
        var origin = CGPoint(x: anchor.x - d * 0.45, y: anchor.y - d * 0.55)
        origin.x = min(max(origin.x, unit), imageW - d - unit)
        origin.y = min(max(origin.y, unit), imageH - d - unit)
        let circle = CGRect(x: origin.x, y: origin.y, width: d, height: d)

        ctx.setFillColor(halo)
        ctx.fillEllipse(in: circle.insetBy(dx: -unit * 1.1, dy: -unit * 1.1))
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: circle)

        let prev = NSGraphicsContext.current
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = gc
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: d * 0.58, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ])
        let size = text.size()
        text.draw(in: CGRect(x: circle.minX,
                             y: circle.midY - size.height / 2,
                             width: circle.width,
                             height: size.height))
        NSGraphicsContext.current = prev
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Model
//
// A Guide is an ordered list of Steps. Screenshots live on disk from the moment
// they are taken (see Img.maxEdge for why); a Step holds the URL, the geometry,
// and the words. `guide.json` is rewritten after every mutation so a crash mid
// recording costs you nothing but the app's window state.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class GuideStep {
    let id: UUID
    var imageURL: URL

    /// 0…1, top-left origin, relative to the screen the click happened on.
    var click: CGPoint
    var target: CGRect?

    var appName: String
    var windowTitle: String
    var elementLabel: String
    var verb: String                 // "Click", "Double-click", "Right-click"…

    /// What the user typed. Empty means "fall back to `autoText`".
    var note: String

    /// Areas painted over before anything else is drawn.
    var redactions: [Redaction] = []
    /// Things drawn on top: arrows, outlines, freehand, text.
    var markups: [Markup] = []
    /// The automatic red box/ring. Turned off when the Accessibility guess was
    /// wrong and you have drawn your own — otherwise you get two markers
    /// disagreeing, and no way to remove the one that is misleading.
    var showHighlight = true

    /// Next draw-order number across both lists.
    var nextSeq: Int {
        (redactions.map(\.seq) + markups.map(\.seq)).max().map { $0 + 1 } ?? 1
    }

    var annotationCount: Int { redactions.count + markups.count }

    private var thumbCache: NSImage?

    init(id: UUID = UUID(), imageURL: URL, click: CGPoint, target: CGRect?,
         appName: String, windowTitle: String, elementLabel: String,
         verb: String, note: String = "") {
        self.id = id
        self.imageURL = imageURL
        self.click = click
        self.target = target
        self.appName = appName
        self.windowTitle = windowTitle
        self.elementLabel = elementLabel
        self.verb = verb
        self.note = note
    }

    /// The rule-based sentence, used until the user replaces it. Deliberately
    /// plain — it is a placeholder that reads as a real instruction, not a
    /// guess dressed up as prose.
    var autoText: String {
        let label = elementLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return appName.isEmpty ? "\(verb) “\(label)”"
                                   : "\(verb) “\(label)” in \(appName)"
        }
        if !appName.isEmpty { return "\(verb) in \(appName)" }
        return verb
    }

    var displayText: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? autoText : note
    }

    /// The small grey line under a step: the window it happened in, and the
    /// name of the thing that was clicked.
    ///
    /// Window titles are a dumping ground. Chrome alone appends the signed-in
    /// account, the profile name, the app name and a memory badge, so a real
    /// title reads:
    ///
    ///     Inbox - someone@a-school.k12.va.us - A-School Mail
    ///       - High memory usage - 2.2 GB - Google Chrome - Name (a-school.k12.va.us)
    ///
    /// Putting that in a guide leaks the author's email address to everyone
    /// they send it to, and truncating it just cuts the address in half. So the
    /// title is taken apart on " - " and each piece is judged on its own.
    var contextLine: String {
        var parts: [String] = []

        let window = Self.cleanWindowTitle(windowTitle, appName: appName)
        if !window.isEmpty { parts.append(window) }

        // The element name earns its place only when it is not already visible.
        // With no note the step text is "Click “Save” in Preview" and repeating
        // "Save" underneath is just noise.
        let element = elementLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !element.isEmpty,
           !Self.looksLikeCode(element),
           !displayText.localizedCaseInsensitiveContains(element),
           !window.localizedCaseInsensitiveContains(element) {
            parts.append(element)
        }

        return Self.trim(parts.joined(separator: " · "), to: 74)
    }

    /// Everything from the app's own name onward is furniture — the app name,
    /// the signed-in profile, the memory badge — and what is left gets each
    /// segment scrubbed for addresses and domains.
    static func cleanWindowTitle(_ raw: String, appName: String) -> String {
        var segments = raw.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if !appName.isEmpty,
           let appIndex = segments.firstIndex(where: {
               $0.caseInsensitiveCompare(appName) == .orderedSame
           }) {
            segments = Array(segments[..<appIndex])
        }
        return segments.compactMap(scrub).joined(separator: " - ")
    }

    /// One title segment, cleaned — or nil if the whole segment was identity or
    /// noise.
    private static func scrub(_ segment: String) -> String? {
        guard !segment.isEmpty, !isNoise(segment) else { return nil }

        let tokens = segment.split(separator: " ").map(String.init)
        // "Name (a-school.k12.va.us)" is a browser profile label: the
        // parenthesised domain means the whole segment is about *who* is signed
        // in, so the name beside it goes too. A bare domain is different —
        // "A-School Mail" keeps the "Mail".
        if tokens.contains(where: { isIdentity($0) && $0.hasPrefix("(") }) { return nil }

        let kept = tokens.filter { !isIdentity($0) }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? nil : kept
    }

    /// Any dotted token ending in letters looks like a domain — including
    /// `Handout.pdf`, and a window title is very often a filename. So a
    /// two-part token has to end in a real TLD to count, three or more parts is
    /// domain-shaped enough on its own, and a known file extension is never one.
    private static let fileExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages",
        "numbers", "txt", "rtf", "csv", "md", "html", "htm", "png", "jpg",
        "jpeg", "gif", "heic", "svg", "webp", "mp3", "mp4", "mov", "m4a", "wav",
        "zip", "dmg", "app", "swift", "py", "js", "ts", "json", "xml", "log",
    ]

    private static let commonTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "io", "co", "us", "uk",
        "ca", "au", "de", "fr", "es", "it", "nl", "eu", "info", "biz", "dev",
        "ai", "xyz", "online", "site",
    ]

    /// An email address, or a bare domain like `a-school.k12.va.us`.
    private static func isIdentity(_ token: String) -> Bool {
        if token.contains("@") { return true }
        let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>,.;:·"))
        guard bare.contains(".") else { return false }
        let pieces = bare.split(separator: ".").map { $0.lowercased() }
        guard pieces.count >= 2, let tld = pieces.last,
              tld.count >= 2, tld.count <= 6, tld.allSatisfy(\.isLetter)
        else { return false }
        if fileExtensions.contains(tld) { return false }
        if pieces.count >= 3 { return true }
        return commonTLDs.contains(tld)
    }

    /// Chrome's memory-saver badge, which is two whole segments of nothing.
    private static func isNoise(_ segment: String) -> Bool {
        if segment.caseInsensitiveCompare("High memory usage") == .orderedSame { return true }
        return segment.range(of: #"^\d+(\.\d+)?\s?(KB|MB|GB|TB)$"#,
                             options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `menuOptions`, `btn-primary`, `nav_item` — an internal identifier that
    /// the Accessibility API handed over because the control had no real name.
    /// Accurate, and useless to a reader.
    static func looksLikeCode(_ label: String) -> Bool {
        guard !label.contains(" ") else { return false }
        if label.contains("_") || label.contains("-") { return true }
        let body = label.dropFirst()
        return body.contains(where: \.isUppercase) && body.contains(where: \.isLowercase)
    }

    /// Shortens on a boundary. Cutting at a fixed character count is what
    /// produced "…Waynesbo…" — half an address, which is worse than either the
    /// whole thing or none of it.
    private static func trim(_ line: String, to limit: Int) -> String {
        guard line.count > limit else { return line }
        var segments = line.components(separatedBy: " - ")
        while segments.count > 1,
              segments.joined(separator: " - ").count > limit {
            segments.removeLast()
        }
        var out = segments.joined(separator: " - ")
        if out.count > limit {
            let cut = out.prefix(limit)
            out = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)])
        }
        return out.trimmingCharacters(in: .whitespaces) + "…"
    }

    var isUserWritten: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Full-size screenshot, redacted and then annotated. Rendered on demand:
    /// keeping annotated copies resident is what blows the memory budget.
    ///
    /// Redaction happens first and inside this one function on purpose — every
    /// export, every thumbnail and the editor preview all come through here, so
    /// none of them can render an unredacted step by forgetting a step.
    func annotated(number: Int) -> CGImage? {
        guard let raw = Img.readPNG(imageURL) else { return nil }
        guard let clean = Annotator.redact(raw, with: redactions) else { return nil }
        let highlighted = showHighlight
            ? Annotator.annotate(clean, click: click, target: target, number: number)
            : clean
        guard let highlighted else { return nil }
        return Annotator.draw(markups, on: highlighted)
    }

    func thumbnail(number: Int) -> NSImage? {
        if let cached = thumbCache { return cached }
        guard let full = annotated(number: number),
              let small = Img.redraw(full, to: thumbSize(for: full))
        else { return nil }
        let image = NSImage(cgImage: small,
                            size: NSSize(width: small.width / 2, height: small.height / 2))
        thumbCache = image
        return image
    }

    func invalidateThumbnail() { thumbCache = nil }

    private func thumbSize(for image: CGImage) -> CGSize {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(320 / w, 200 / h, 1)
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }

    // MARK: Persistence

    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "id": id.uuidString,
            "image": imageURL.lastPathComponent,
            "clickX": click.x, "clickY": click.y,
            "app": appName, "window": windowTitle,
            "label": elementLabel, "verb": verb, "note": note,
        ]
        if !redactions.isEmpty { d["redactions"] = redactions.map(\.dictionary) }
        if !markups.isEmpty { d["markups"] = markups.map(\.dictionary) }
        if !showHighlight { d["showHighlight"] = false }
        if let t = target {
            d["targetX"] = t.minX; d["targetY"] = t.minY
            d["targetW"] = t.width; d["targetH"] = t.height
        }
        return d
    }

    static func from(_ d: [String: Any], folder: URL) -> GuideStep? {
        guard let name = d["image"] as? String,
              let cx = d["clickX"] as? CGFloat, let cy = d["clickY"] as? CGFloat
        else { return nil }
        var target: CGRect?
        if let x = d["targetX"] as? CGFloat, let y = d["targetY"] as? CGFloat,
           let w = d["targetW"] as? CGFloat, let h = d["targetH"] as? CGFloat {
            target = CGRect(x: x, y: y, width: w, height: h)
        }
        let step = GuideStep(id: UUID(uuidString: d["id"] as? String ?? "") ?? UUID(),
                         imageURL: folder.appendingPathComponent(name),
                         click: CGPoint(x: cx, y: cy),
                         target: target,
                         appName: d["app"] as? String ?? "",
                         windowTitle: d["window"] as? String ?? "",
                         elementLabel: d["label"] as? String ?? "",
                         verb: d["verb"] as? String ?? "Click",
                         note: d["note"] as? String ?? "")
        step.redactions = (d["redactions"] as? [[String: Any]] ?? [])
            .compactMap(Redaction.from)
        step.markups = (d["markups"] as? [[String: Any]] ?? []).compactMap(Markup.from)
        step.showHighlight = d["showHighlight"] as? Bool ?? true
        return step
    }
}

@MainActor
final class Guide {
    static let didChange = Notification.Name("ScribeGuideDidChange")

    private(set) var folder: URL
    var title: String { didSet { save() } }
    private(set) var steps: [GuideStep] = []
    private var shotCounter = 0

    /// ~/Library/Application Support/Scribe/<timestamp>/
    ///
    /// Only a path — nothing is written until the first step arrives. An
    /// eagerly created folder meant every launch and every erase left an empty
    /// session on disk, which then showed up in the guide library as a row of
    /// nothing and made "the most recent guide" mean the wrong thing.
    static func newFolder() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return root.appendingPathComponent(f.string(from: Date()), isDirectory: true)
    }

    static var root: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe", isDirectory: true)
    }

    private func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    init() {
        let f = DateFormatter()
        f.dateStyle = .medium
        folder = Guide.newFolder()
        title = "Untitled Guide"
        _ = f
    }

    var isEmpty: Bool { steps.isEmpty }
    var count: Int { steps.count }

    /// Reopens a session folder written by a previous run. Steps whose PNG has
    /// gone missing are dropped rather than becoming rows with no picture.
    @discardableResult
    func load(from folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("guide.json")),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = payload["steps"] as? [[String: Any]]
        else { return false }

        self.folder = folder
        title = payload["title"] as? String ?? "Untitled Guide"
        steps = raw.compactMap { GuideStep.from($0, folder: folder) }
            .filter { FileManager.default.fileExists(atPath: $0.imageURL.path) }
        // Keep new screenshots from overwriting the ones already in the folder.
        shotCounter = steps.count
        changed()
        return !steps.isEmpty
    }

    /// True if a session folder holds a guide with at least one step. Erasing
    /// leaves behind a folder with a valid but empty `guide.json`, and without
    /// this check that empty folder is the newest one — so "Reopen Last Guide"
    /// would faithfully reopen the emptiness it had just created.
    private static func hasSteps(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("guide.json")),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = payload["steps"] as? [[String: Any]]
        else { return false }
        return !steps.isEmpty
    }

    /// The most recent session folder that actually has steps in it, or nil.
    static func mostRecentFolder() -> URL? {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return folders
            .filter { hasSteps($0) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da > db
            }
            .first
    }

    /// Parks the current guide and starts an empty one.
    ///
    /// Non-destructive, and it is worth being clear about that: the previous
    /// guide's folder and screenshots are left exactly where they are, so it
    /// stays in the library and can be reopened. This was called `reset` and
    /// surfaced as "Erase Current Guide…", which described something the code
    /// has never done — and meant nobody could find the New Guide button,
    /// because it was wearing a warning label.
    ///
    /// Actually deleting a guide is the library's Delete, which moves the
    /// folder to the Trash.
    func startNew() {
        steps.removeAll()
        shotCounter = 0
        folder = Guide.newFolder()
        title = "Untitled Guide"
        changed()
    }

    /// Writes the screenshot and appends the step. Returns nil if the PNG could
    /// not be written, in which case the click is dropped rather than becoming
    /// a step with no picture.
    @discardableResult
    func append(image: CGImage, click: CGPoint, target: CGRect?,
                appName: String, windowTitle: String, elementLabel: String,
                verb: String) -> GuideStep? {
        shotCounter += 1
        ensureFolder()
        let url = folder.appendingPathComponent(String(format: "shot-%03d.png", shotCounter))
        guard Img.writePNG(Img.downscale(image), to: url) else {
            Diag.log("FAILED to write \(url.lastPathComponent)")
            return nil
        }
        let step = GuideStep(imageURL: url, click: click, target: target,
                             appName: appName, windowTitle: windowTitle,
                             elementLabel: elementLabel, verb: verb)
        steps.append(step)
        changed()
        return step
    }

    func remove(at index: Int) {
        guard steps.indices.contains(index) else { return }
        steps.remove(at: index)
        renumberThumbnails(from: index)
        changed()
    }

    /// Returns the index the step ended up at, so the table can follow it.
    @discardableResult
    func move(from index: Int, by delta: Int) -> Int {
        let target = index + delta
        guard steps.indices.contains(index), steps.indices.contains(target) else { return index }
        steps.swapAt(index, target)
        renumberThumbnails(from: min(index, target))
        changed()
        return target
    }

    // MARK: Redactions

    func addRedaction(_ redaction: Redaction, at index: Int) {
        guard steps.indices.contains(index), redaction.rect.width > 0.002,
              redaction.rect.height > 0.002 else { return }
        var stamped = redaction
        stamped.seq = steps[index].nextSeq
        steps[index].redactions.append(stamped)
        steps[index].invalidateThumbnail()
        changed()
    }

    func addMarkup(_ markup: Markup, at index: Int) {
        guard steps.indices.contains(index), !markup.points.isEmpty else { return }
        if markup.kind == .text && markup.text.isEmpty { return }
        var stamped = markup
        stamped.seq = steps[index].nextSeq
        steps[index].markups.append(stamped)
        steps[index].invalidateThumbnail()
        changed()
    }

    func setShowHighlight(_ show: Bool, at index: Int) {
        guard steps.indices.contains(index), steps[index].showHighlight != show else { return }
        steps[index].showHighlight = show
        steps[index].invalidateThumbnail()
        changed()
    }

    /// Removes whatever is under `point` — cover or drawing, whichever was
    /// added most recently. One gesture for both, because from the user's side
    /// they are all just things sitting on the picture.
    @discardableResult
    func removeAnnotation(at index: Int, containing point: CGPoint) -> Bool {
        guard steps.indices.contains(index) else { return false }
        let step = steps[index]

        let redactionHit = step.redactions.enumerated()
            .filter { $0.element.rect.contains(point) }
            .max { $0.element.seq < $1.element.seq }
        let markupHit = step.markups.enumerated()
            .filter { $0.element.bounds.contains(point) }
            .max { $0.element.seq < $1.element.seq }

        // Whichever is on top wins.
        if let markupHit, redactionHit == nil || markupHit.element.seq > redactionHit!.element.seq {
            step.markups.remove(at: markupHit.offset)
        } else if let redactionHit {
            step.redactions.remove(at: redactionHit.offset)
        } else {
            return false
        }
        step.invalidateThumbnail()
        changed()
        return true
    }

    /// Pops the most recent annotation of either kind.
    func undoLastAnnotation(at index: Int) {
        guard steps.indices.contains(index) else { return }
        let step = steps[index]
        let lastRedaction = step.redactions.map(\.seq).max() ?? -1
        let lastMarkup = step.markups.map(\.seq).max() ?? -1
        guard lastRedaction >= 0 || lastMarkup >= 0 else { return }

        if lastMarkup >= lastRedaction {
            if let i = step.markups.firstIndex(where: { $0.seq == lastMarkup }) {
                step.markups.remove(at: i)
            }
        } else if let i = step.redactions.firstIndex(where: { $0.seq == lastRedaction }) {
            step.redactions.remove(at: i)
        }
        step.invalidateThumbnail()
        changed()
    }

    func clearAnnotations(at index: Int) {
        guard steps.indices.contains(index), steps[index].annotationCount > 0 else { return }
        steps[index].redactions.removeAll()
        steps[index].markups.removeAll()
        steps[index].invalidateThumbnail()
        changed()
    }

    /// Copies one step's redactions onto every other step.
    ///
    /// The case this exists for: a sidebar, header or account chip that carries
    /// a name and is in the same place in all twenty screenshots. Redacting it
    /// twenty times by hand is how a redaction gets missed.
    @discardableResult
    func applyRedactionsEverywhere(from index: Int) -> Int {
        guard steps.indices.contains(index) else { return 0 }
        let source = steps[index].redactions
        guard !source.isEmpty else { return 0 }

        var changedCount = 0
        for i in steps.indices where i != index {
            var added = false
            for redaction in source where !steps[i].redactions.contains(redaction) {
                steps[i].redactions.append(redaction)
                added = true
            }
            if added { steps[i].invalidateThumbnail(); changedCount += 1 }
        }
        if changedCount > 0 { changed() }
        return changedCount
    }

    var redactionCount: Int { steps.reduce(0) { $0 + $1.redactions.count } }

    /// Burns the redactions into the stored screenshots and forgets them.
    ///
    /// Until this runs, the PNGs in the session folder still hold the original
    /// pixels — exports are clean, but the folder is not. Anyone handing over a
    /// machine, syncing the folder, or sharing a session directory needs the
    /// pixels actually gone. Irreversible by design; the caller confirms.
    @discardableResult
    func flattenRedactions() -> Int {
        var flattened = 0
        for step in steps where !step.redactions.isEmpty {
            guard let raw = Img.readPNG(step.imageURL),
                  let clean = Annotator.redact(raw, with: step.redactions),
                  Img.writePNG(clean, to: step.imageURL)
            else {
                Diag.log("flatten FAILED for \(step.imageURL.lastPathComponent)")
                continue
            }
            step.redactions.removeAll()
            step.invalidateThumbnail()
            flattened += 1
        }
        if flattened > 0 { changed() }
        return flattened
    }

    func setNote(_ text: String, at index: Int) {
        guard steps.indices.contains(index) else { return }
        steps[index].note = text
        changed()
    }

    /// Step numbers are burned into the thumbnails, so anything that shifts
    /// positions has to throw the affected ones away.
    private func renumberThumbnails(from index: Int) {
        for i in index..<steps.count { steps[i].invalidateThumbnail() }
    }

    private func changed() {
        save()
        NotificationCenter.default.post(name: Guide.didChange, object: nil)
    }

    func save() {
        // An empty guide has nothing worth a folder; see `newFolder`.
        guard !steps.isEmpty else { return }
        ensureFolder()
        let payload: [String: Any] = [
            "title": title,
            "savedAt": ISO8601DateFormatter().string(from: Date()),
            "steps": steps.map(\.dictionary),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted])
        else { return }
        try? data.write(to: folder.appendingPathComponent("guide.json"))
    }
}
