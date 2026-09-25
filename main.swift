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
    var onFrame: ((CGImage) -> Void)?

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

        box.output.onFrame = { [weak box] image in box?.latest = image }

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
        cfg.queueDepth = 3
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Export themes
//
// School branding for exported guides. Only the document chrome is themed —
// the title, the step-number badges, the rules, and an optional logo.
//
// The *annotation* accent stays red on purpose. That red box is a wayfinding
// mark on somebody else's screenshot and it has to survive whatever colours the
// underlying app uses; a purple box on a purple site is invisible, and a guide
// nobody can follow is a worse outcome than one that is off-brand.
// ─────────────────────────────────────────────────────────────────────────────

struct ExportTheme: Equatable {
    let id: String
    let name: String
    /// Badges, rules, the title underline.
    let accentHex: String
    /// A second brand colour, for the thin bar under the header. Equal to
    /// `accentHex` for single-colour themes.
    let secondaryHex: String
    /// A third, used only where a theme has one; otherwise the secondary again.
    let tertiaryHex: String
    let inkHex: String
    let mutedHex: String
    let ruleHex: String
    /// PNG in the app bundle's Resources, drawn above the title. Nil for
    /// themes with no artwork.
    let logoResource: String?

    static let scribe = ExportTheme(
        id: "scribe", name: "Scribe (default)",
        accentHex: "#E0234A", secondaryHex: "#E0234A", tertiaryHex: "#E0234A",
        inkHex: "#1A1D21", mutedHex: "#5F6672", ruleHex: "#E3E5E8",
        logoResource: nil)

    /// Kate Collins Middle School — purple and black, badger mascot.
    ///
    /// The purple is lifted from the supplied artwork's #260C47, which is so
    /// dark it reads as black behind a white number. Same hue, more light, so
    /// a badge is legibly purple rather than a black dot.
    static let kcms = ExportTheme(
        id: "kcms", name: "Kate Collins (Badgers)",
        accentHex: "#4B1F87", secondaryHex: "#260C47", tertiaryHex: "#1A1A1E",
        inkHex: "#16161A", mutedHex: "#5A5560", ruleHex: "#E1DDE8",
        logoResource: "kcms-logo")

    /// Waynesboro Public Schools — blue, orange, green.
    static let wps = ExportTheme(
        id: "wps", name: "Waynesboro Public Schools",
        accentHex: "#1B85C8", secondaryHex: "#F07E26", tertiaryHex: "#7CB943",
        inkHex: "#1A1D21", mutedHex: "#5F6672", ruleHex: "#DDE6EC",
        logoResource: nil)

    static let all: [ExportTheme] = [.scribe, .kcms, .wps]

    static func with(id: String) -> ExportTheme {
        all.first { $0.id == id } ?? .scribe
    }

    var accent: CGColor { Self.color(accentHex) }
    var secondary: CGColor { Self.color(secondaryHex) }
    var tertiary: CGColor { Self.color(tertiaryHex) }
    var ink: CGColor { Self.color(inkHex) }
    var muted: CGColor { Self.color(mutedHex) }
    var rule: CGColor { Self.color(ruleHex) }

    var accentNS: NSColor { NSColor(cgColor: accent) ?? .systemRed }
    var inkNS: NSColor { NSColor(cgColor: ink) ?? .black }
    var mutedNS: NSColor { NSColor(cgColor: muted) ?? .gray }
    var ruleNS: NSColor { NSColor(cgColor: rule) ?? .lightGray }

    /// The logo, or nil for a theme without one — or one whose file did not
    /// make it into the bundle, which is a build problem and not worth
    /// crashing an export over.
    var logo: CGImage? {
        guard let logoResource,
              let url = Bundle.main.url(forResource: logoResource, withExtension: "png")
        else { return nil }
        return Img.readPNG(url)
    }

    private static func color(_ hex: String) -> CGColor {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        return CGColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Export
//
// HTML is the primary format and the other two hang off it. It is one file
// with the images base64'd in, so it can be emailed, dropped in a Drive
// folder, or opened from a flash drive with nothing to go missing — which
// matters more than file size for something handed to a colleague.
//
// PDF is that same HTML rendered by WKWebView. Markdown is a folder, because
// Markdown has no way to carry its own images.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum Export {

    // MARK: HTML

    static func html(_ guide: Guide, embedImages: Bool = true,
                     imageNames: [Int: String] = [:]) -> String {
        let theme = Settings.shared.exportTheme
        var body = ""
        for (i, step) in guide.steps.enumerated() {
            let n = i + 1
            var src = ""
            if embedImages {
                if let image = step.annotated(number: n), let data = Img.pngData(image) {
                    src = "data:image/png;base64,\(data.base64EncodedString())"
                }
            } else {
                src = "images/\(imageNames[n] ?? "")"
            }
            let context = step.contextLine
            body += """
                <li class="step">
                  <div class="head"><span class="num">\(n)</span>
                    <div><p class="text">\(escape(step.displayText))</p>
                    \(context.isEmpty ? "" : "<p class=\"ctx\">\(escape(context))</p>")</div>
                  </div>
                  \(src.isEmpty ? "" : "<img src=\"\(src)\" alt=\"Step \(n)\">")
                </li>

                """
        }

        let f = DateFormatter()
        f.dateStyle = .long
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(guide.title))</title>
        <style>
          :root {
            --ink: \(theme.inkHex); --muted: \(theme.mutedHex); --line: \(theme.ruleHex);
            --accent: \(theme.accentHex); --accent-2: \(theme.secondaryHex);
            --accent-3: \(theme.tertiaryHex); --bg: #ffffff; --card: #ffffff;
          }
          @media (prefers-color-scheme: dark) {
            :root { --ink:#e8eaed; --muted:#9aa1ac; --line:#2a2e37;
                    --bg:#14161a; --card:#1b1e24; }
          }
          * { box-sizing: border-box; }
          body { margin: 0; background: var(--bg); color: var(--ink);
                 font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI",
                       Helvetica, Arial, sans-serif; }
          main { max-width: 860px; margin: 0 auto; padding: 48px 24px 80px; }
          h1 { font-size: 30px; line-height: 1.2; margin: 0 0 6px; letter-spacing: -0.01em; }
          .meta { color: var(--muted); font-size: 13px; margin: 0 0 36px; }
          ol { list-style: none; margin: 0; padding: 0; }
          .step { margin: 0 0 34px; padding: 0 0 30px; border-bottom: 1px solid var(--line); }
          .step:last-child { border-bottom: 0; }
          .head { display: flex; gap: 14px; align-items: flex-start; margin-bottom: 14px; }
          .num { flex: 0 0 28px; height: 28px; border-radius: 50%;
                 background: var(--accent); color: #fff; font-size: 14px;
                 font-weight: 700; display: flex; align-items: center;
                 justify-content: center; margin-top: 1px; }
          .text { margin: 2px 0 0; font-size: 17px; font-weight: 500; }
          .ctx { margin: 3px 0 0; font-size: 12.5px; color: var(--muted); }
          img { display: block; width: 100%; height: auto; border-radius: 10px;
                border: 1px solid var(--line); }
          footer { color: var(--muted); font-size: 12px; margin-top: 40px; }
          .logo { display: block; height: 86px; width: auto; margin: 0 0 14px; }
          .bar { display: flex; height: 5px; border-radius: 3px; overflow: hidden;
                 margin: 0 0 18px; }
          .bar i { flex: 1; }
          .bar i:nth-child(1) { background: var(--accent); }
          .bar i:nth-child(2) { background: var(--accent-2); }
          .bar i:nth-child(3) { background: var(--accent-3); }
          @media print {
            :root { --bg:#fff; --card:#fff; --ink:#111; --line:#ddd; --muted:#666; }
            body { font-size: 12pt; }
            main { padding: 0; max-width: none; }
            .step { break-inside: avoid; page-break-inside: avoid; }
            footer { display: none; }
          }
        </style></head>
        <body><main>
        \(themeBanner(theme))
          <h1>\(escape(guide.title))</h1>
          <p class="meta">\(guide.count) step\(guide.count == 1 ? "" : "s") · \(f.string(from: Date()))</p>
          <ol>
        \(body)  </ol>
          <footer>Recorded with Scribe.</footer>
        </main></body></html>
        """
    }

    /// The logo and the three-colour bar above the title. Themes without
    /// artwork still get the bar, which is what carries the branding when there
    /// is no mark to show.
    private static func themeBanner(_ theme: ExportTheme) -> String {
        var out = ""
        if let logo = theme.logo,
           let data = Img.pngData(Img.downscale(logo, maxEdge: 480)) {
            out += "<img class=\"logo\" alt=\"\" "
                + "src=\"data:image/png;base64,\(data.base64EncodedString())\">\n"
        }
        out += "<div class=\"bar\"><i></i><i></i><i></i></div>"
        return out
    }

    // MARK: Email / Gmail

    /// Widest an image goes in an email. Gmail's reading pane is around 600 pt,
    /// and a 2x asset for it is 1200 px — past that is bytes nobody sees.
    private static let emailImageWidth: CGFloat = 1200

    /// HTML that survives being pasted into Gmail.
    ///
    /// Gmail's composer throws away `<style>` blocks, `<head>`, classes, and
    /// anything it does not recognise, then rewrites what is left. So this
    /// renderer shares nothing with `html(_:)`:
    ///
    ///   • every rule is an inline `style` attribute, because there is no
    ///     stylesheet to survive
    ///   • layout is `<table>`, not flexbox or grid, which Gmail drops
    ///   • images are JPEG data URIs with a real `width` attribute — Gmail
    ///     honours the attribute and ignores much of the CSS around it
    ///   • no `@media`, no dark-mode variants, no web fonts
    ///
    /// Two things learned from looking at the rendered output rather than the
    /// markup:
    ///
    ///   • **Longhand, never the `font:` shorthand.** Gmail rewrites shorthand
    ///     unevenly, so some elements keep their size and weight while others
    ///     silently fall back — which is exactly what "the font sizes look
    ///     wonky" turns out to be.
    ///   • **Line heights in px, and the same px for the badge and the text
    ///     beside it.** A 22 px circle next to a 22 px line box lines up on its
    ///     own; anything relying on a unitless line-height or `vertical-align`
    ///     drifts, because Gmail normalises those away.
    static func emailHTML(_ guide: Guide) -> String {
        let theme = Settings.shared.exportTheme
        let ink = theme.inkHex, muted = theme.mutedHex
        let rule = theme.ruleHex, accent = theme.accentHex
        let family = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"
        let base = "font-family:\(family);"
        let line = 22          // shared by the badge and the step text

        var rows = ""
        for (i, step) in guide.steps.enumerated() {
            let n = i + 1
            let first = i == 0

            var img = ""
            if let full = step.annotated(number: n) {
                let sized = Img.downscale(full, maxEdge: emailImageWidth)
                if let data = Img.jpegData(sized) {
                    // Half the pixel width, so a 2x asset displays at 1x.
                    let shown = Int((CGFloat(sized.width) / 2).rounded())
                    img = "<img width=\"\(shown)\" alt=\"Step \(n)\" "
                        + "src=\"data:image/jpeg;base64,\(data.base64EncodedString())\" "
                        + "style=\"display:block;width:100%;max-width:\(shown)px;height:auto;"
                        + "margin:12px 0 0;border:1px solid \(rule);border-radius:6px;\">"
                }
            }

            let context = step.contextLine
            let divider = first ? "" : "border-top:1px solid \(rule);"
            let topPad = first ? 0 : 22
            let contextDiv = context.isEmpty ? "" :
                "<div style=\"\(base)font-size:12px;line-height:18px;color:\(muted);"
                + "padding-top:3px;\">\(escape(context))</div>"

            rows += """
            <tr>
            <td width="24" valign="top" style="\(divider)width:24px;padding:\(topPad)px 12px 26px 0;">
            <div style="\(base)width:22px;height:22px;line-height:22px;border-radius:11px;\
            background-color:\(accent);color:#ffffff;font-size:12px;font-weight:700;\
            text-align:center;">\(n)</div>
            </td>
            <td valign="top" style="\(divider)padding:\(topPad)px 0 26px 0;">
            <div style="\(base)font-size:15px;font-weight:500;line-height:\(line)px;\
            color:\(ink);">\(escape(step.displayText))</div>
            \(contextDiv)
            \(img)
            </td>
            </tr>

            """
        }

        // Gmail keeps a table of solid cells far more reliably than it keeps a
        // flex bar or a border, so the brand stripe is three <td>s.
        var banner = ""
        // PNG, not JPEG, for the logo alone. Screenshots are JPEG because they
        // are opaque and enormous; a logo is small and has a transparent
        // background, and JPEG has no alpha — encoding it that way puts the
        // mascot in a black box in the middle of the email.
        if let logo = theme.logo,
           let data = Img.pngData(Img.downscale(logo, maxEdge: 400)) {
            banner += "<img height=\"64\" alt=\"\" "
                + "src=\"data:image/png;base64,\(data.base64EncodedString())\" "
                + "style=\"display:block;height:64px;width:auto;margin:0 0 10px;\">"
        }
        banner += "<table cellpadding=\"0\" cellspacing=\"0\" border=\"0\" "
            + "style=\"width:100%;border-collapse:collapse;margin:0 0 16px;\"><tr>"
            + "<td style=\"height:5px;line-height:5px;font-size:0;"
            + "background-color:\(theme.accentHex);\">&nbsp;</td>"
            + "<td style=\"height:5px;line-height:5px;font-size:0;"
            + "background-color:\(theme.secondaryHex);\">&nbsp;</td>"
            + "<td style=\"height:5px;line-height:5px;font-size:0;"
            + "background-color:\(theme.tertiaryHex);\">&nbsp;</td></tr></table>"

        return """
        <div style="\(base)font-size:15px;line-height:\(line)px;color:\(ink);max-width:680px;">
        \(banner)
        <div style="\(base)font-size:20px;line-height:26px;font-weight:600;color:\(ink);">\
        \(escape(guide.title))</div>
        <div style="\(base)font-size:12px;line-height:18px;color:\(muted);padding:4px 0 20px;">\
        \(guide.count) step\(guide.count == 1 ? "" : "s")</div>
        <table cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;">
        \(rows)</table>
        </div>
        """
    }

    /// Plain-text version, so pasting somewhere that takes no formatting still
    /// gives a usable list rather than a wall of base64.
    static func plainText(_ guide: Guide) -> String {
        var out = "\(guide.title)\n\n"
        for (i, step) in guide.steps.enumerated() {
            out += "\(i + 1). \(step.displayText)\n"
            let context = step.contextLine
            if !context.isEmpty { out += "   (\(context))\n" }
        }
        return out
    }

    /// Puts the guide on the clipboard as rich HTML, ready for ⌘V into a Gmail
    /// compose window. Pasting is the only route in — Gmail has no "paste HTML
    /// source" — so the clipboard carries the rendered flavour, with a plain
    /// text fallback underneath for anywhere that will not take it.
    @discardableResult
    static func copyForEmail(_ guide: Guide) -> Int {
        let html = emailHTML(guide)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(html, forType: .html)
        board.setString(plainText(guide), forType: .string)
        return html.utf8.count
    }

    // MARK: Markdown

    /// Writes `<folder>/<name>.md` plus `<folder>/images/`. Markdown cannot
    /// carry its own pictures, so this export is a directory by necessity.
    static func markdown(_ guide: Guide, to folder: URL) throws {
        let images = folder.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

        var out = "# \(guide.title)\n\n"
        for (i, step) in guide.steps.enumerated() {
            let n = i + 1
            let name = String(format: "step-%03d.png", n)
            if let image = step.annotated(number: n) {
                _ = Img.writePNG(image, to: images.appendingPathComponent(name))
            }
            out += "## \(n). \(step.displayText)\n\n"
            let context = step.contextLine
            if !context.isEmpty { out += "_\(context)_\n\n" }
            out += "![Step \(n)](images/\(name))\n\n"
        }
        try out.write(to: folder.appendingPathComponent("guide.md"),
                      atomically: true, encoding: .utf8)
    }

    // MARK: PDF

    /// How many steps go on a page.
    ///
    /// `.fit` is the flowing layout: each step takes the room its screenshot
    /// wants and breaks to a new page when it will not fit. Good for reading.
    /// A fixed count gives every step an identical slot, which is what you want
    /// when the guide is going to be printed and handed out — one step per page
    /// for a wall poster, four for a compact reference sheet.
    enum PageDensity: Equatable {
        case fit
        case fixed(Int)

        static let choices: [PageDensity] = [.fit, .fixed(1), .fixed(2), .fixed(3), .fixed(4)]

        var label: String {
            switch self {
            case .fit:            return "As many as fit"
            case .fixed(1):       return "1 per page"
            case .fixed(4):       return "4 per page (2 × 2)"
            case .fixed(let n):   return "\(n) per page"
            }
        }

        var storageValue: Int {
            switch self {
            case .fit:          return 0
            case .fixed(let n): return n
            }
        }

        static func from(storage: Int) -> PageDensity {
            (1...4).contains(storage) ? .fixed(storage) : .fit
        }
    }

    /// Drawn straight into a CGPDFContext rather than rendered by WebKit.
    /// Both WebKit routes were tried on this file and both are wrong for it:
    ///
    ///   `WKWebView.createPDF`      returns the whole guide as ONE page,
    ///                              however long it is — unprintable.
    ///   `WKWebView.printOperation` ran away: 80 MB and still climbing for a
    ///                              two-step guide, never returning.
    ///
    /// Drawing it by hand is about two hundred lines and gives exact control
    /// over where a page breaks, which is the entire reason to want a PDF.
    static func pdf(_ guide: Guide, to url: URL,
                    density: PageDensity = .fit,
                    completion: @escaping (Error?) -> Void) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)     // US Letter, points
        let content = box.insetBy(dx: 52, dy: 52)

        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            completion(CocoaError(.fileWriteUnknown)); return
        }

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        switch density {
        case .fit:            drawFlowing(guide, in: ctx, content: content)
        case .fixed(let n):   drawFixed(guide, in: ctx, content: content, perPage: max(1, n))
        }

        // Order matters and a `defer` gets it wrong: `defer` runs *after* the
        // function body, so the completion handler would fire while the PDF was
        // still unflushed. Anything acting on the file — revealing it in the
        // Finder, mailing it, measuring it — would see a partial document.
        NSGraphicsContext.current = previous
        ctx.closePDF()
        completion(nil)
    }

    // MARK: PDF — shared pieces

    private static var pdfTheme: ExportTheme { Settings.shared.exportTheme }
    private static var pdfAccent: NSColor { pdfTheme.accentNS }
    private static let pdfIndent: CGFloat = 30

    private static func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    private static func paragraph(_ centred: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = centred ? .center : .natural
        return style
    }

    private static func bodyText(_ step: GuideStep, centred: Bool = false) -> NSAttributedString {
        NSAttributedString(string: step.displayText, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph(centred),
        ])
    }

    private static func contextText(_ step: GuideStep,
                                    centred: Bool = false) -> NSAttributedString? {
        let line = step.contextLine
        guard !line.isEmpty else { return nil }
        return NSAttributedString(string: line, attributes: [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: pdfTheme.mutedNS,
            .paragraphStyle: paragraph(centred),
        ])
    }

    /// Draws one step to fill `rect` — badge, text, then the screenshot scaled
    /// to whatever vertical room is left. Both layouts go through here, so a
    /// step looks the same however the pages were divided up.
    /// Draws one step to fill `rect` — badge, text, then the screenshot scaled
    /// to whatever vertical room is left. Both layouts go through here, so a
    /// step looks the same however the pages were divided up.
    ///
    /// `centred` is for the fixed-count layouts. Once several steps share a
    /// page the screenshot is height-constrained, so it comes out narrower than
    /// the column and a left-aligned image leaves a growing band of white down
    /// the right-hand side — most obvious at four per page. Centring makes that
    /// margin symmetrical, and the number and text follow the picture so the
    /// whole slot reads as one deliberate block rather than a left-aligned
    /// paragraph with a centred photo under it.
    ///
    /// The flowing layout stays left-aligned: there the image fills the column,
    /// there is no spare width, and centred body text is harder to read down a
    /// long page.
    private static func drawStep(_ step: GuideStep, number: Int,
                                 in rect: CGRect, ctx: CGContext,
                                 centred: Bool = false,
                                 reservedTextHeight: CGFloat? = nil) {
        let textWidth = centred ? rect.width : rect.width - pdfIndent
        let textX = centred ? rect.minX : rect.minX + pdfIndent
        let body = bodyText(step, centred: centred)
        let sub = contextText(step, centred: centred)
        let bodyH = measure(body, width: textWidth)
        let subH = sub.map { measure($0, width: textWidth) } ?? 0

        var pen = rect.maxY
        let d: CGFloat = 17

        // Centred: the number sits on its own line above the text. Left-aligned:
        // it sits in the gutter beside the first line, which is what makes a
        // flowing page scan as a numbered list.
        let badgeX = centred ? rect.midX - d / 2 : rect.minX
        let badge = CGRect(x: badgeX, y: pen - d - 1, width: d, height: d)
        ctx.setFillColor(pdfAccent.cgColor)
        ctx.fillEllipse(in: badge)
        let numberText = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let numberSize = numberText.size()
        numberText.draw(at: CGPoint(x: badge.midX - numberSize.width / 2,
                                    y: badge.midY - numberSize.height / 2))
        if centred { pen -= d + 7 }

        body.draw(with: CGRect(x: textX, y: pen - bodyH, width: textWidth, height: bodyH),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        pen -= bodyH
        if let sub, subH > 0 {
            pen -= 2
            sub.draw(with: CGRect(x: textX, y: pen - subH, width: textWidth, height: subH),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
            pen -= subH
        }
        pen -= 8

        // In a grid, every cell in the row hands its picture the same starting
        // height, whatever its caption did.
        if let reservedTextHeight { pen = rect.maxY - reservedTextHeight }

        let available = pen - rect.minY
        guard available > 24,
              let shot = step.annotated(number: number)
                  .flatMap({ Img.downscale($0, maxEdge: 1200) })
        else { return }

        var w = textWidth
        var h = w * CGFloat(shot.height) / CGFloat(shot.width)
        if h > available {
            h = available
            w = h * CGFloat(shot.width) / CGFloat(shot.height)
        }
        let x = centred ? rect.midX - w / 2 : rect.minX + pdfIndent
        let frame = CGRect(x: x, y: pen - h, width: w, height: h)
        ctx.draw(shot, in: frame)
        ctx.setStrokeColor(pdfTheme.rule)
        ctx.setLineWidth(0.5)
        ctx.stroke(frame)
    }

    /// Height of the badge-and-text block above the screenshot, laid out the
    /// same way `drawStep` lays it out.
    ///
    /// The grid needs this up front: two cells side by side whose captions wrap
    /// to different numbers of lines would otherwise start their pictures at
    /// different heights, and a row of screenshots that do not line up is the
    /// thing that makes a printed sheet look thrown together.
    static func textBlockHeight(_ step: GuideStep, number: Int,
                                width: CGFloat, centred: Bool) -> CGFloat {
        let textWidth = centred ? width : width - pdfIndent
        let bodyH = measure(bodyText(step, centred: centred), width: textWidth)
        let subH = contextText(step, centred: centred)
            .map { measure($0, width: textWidth) + 2 } ?? 0
        let badge: CGFloat = centred ? 17 + 7 : 0
        return badge + bodyH + subH + 8
    }

    /// Height a step wants when nothing is constraining it.
    private static func naturalHeight(_ step: GuideStep, number: Int,
                                      width: CGFloat, ceiling: CGFloat) -> CGFloat {
        let textWidth = width - pdfIndent
        let bodyH = measure(bodyText(step), width: textWidth)
        let subH = contextText(step).map { measure($0, width: textWidth) } ?? 0
        var imageH: CGFloat = 0
        if let shot = step.annotated(number: number) {
            imageH = textWidth * CGFloat(shot.height) / CGFloat(shot.width)
            imageH = min(imageH, ceiling - bodyH - subH - 34)
        }
        return bodyH + subH + imageH + 30
    }

    /// How tall the title block is, logo and stripe included.
    ///
    /// The fixed layout reserves a band for it on every page and divides what
    /// is left into equal slots, so this has to be known *before* anything is
    /// drawn. Guessing a constant is what put the first step on top of the
    /// title the moment a theme added a logo.
    static func headerHeight(_ guide: Guide, width: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        if Settings.shared.exportTheme.logo != nil { height += pdfLogoHeight + 10 }
        let title = NSAttributedString(string: guide.title, attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold),
        ])
        height += measure(title, width: width)
        let meta = NSAttributedString(string: "0 steps", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
        ])
        height += 4 + measure(meta, width: width) + 32
        return height
    }

    private static let pdfLogoHeight: CGFloat = 54

    private static func drawHeader(_ guide: Guide, in rect: CGRect, ctx: CGContext,
                                   centred: Bool = false) -> CGFloat {
        let title = NSAttributedString(string: guide.title, attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: pdfTheme.inkNS,
            .paragraphStyle: paragraph(centred),
        ])
        let dates = DateFormatter()
        dates.dateStyle = .long
        let meta = NSAttributedString(
            string: "\(guide.count) step\(guide.count == 1 ? "" : "s") · "
                  + dates.string(from: Date()),
            attributes: [.font: NSFont.systemFont(ofSize: 10),
                         .foregroundColor: NSColor.gray,
                         .paragraphStyle: paragraph(centred)])

        var top = rect.maxY
        var used: CGFloat = 0

        // Logo above the title, at the header's alignment.
        if let logo = pdfTheme.logo {
            let h = pdfLogoHeight
            let w = h * CGFloat(logo.width) / CGFloat(logo.height)
            let x = centred ? rect.midX - w / 2 : rect.minX
            ctx.draw(logo, in: CGRect(x: x, y: top - h, width: w, height: h))
            top -= h + 10
            used += h + 10
        }

        let titleH = measure(title, width: rect.width)
        title.draw(with: CGRect(x: rect.minX, y: top - titleH,
                                width: rect.width, height: titleH),
                   options: [.usesLineFragmentOrigin, .usesFontLeading])
        let metaH = measure(meta, width: rect.width)
        meta.draw(with: CGRect(x: rect.minX, y: top - titleH - 4 - metaH,
                               width: rect.width, height: metaH),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])

        // The three-colour stripe, the one piece of branding every theme has.
        let barY = top - titleH - 4 - metaH - 12
        let segment = rect.width / 3
        for (i, colour) in [pdfTheme.accent, pdfTheme.secondary, pdfTheme.tertiary].enumerated() {
            ctx.setFillColor(colour)
            ctx.fill(CGRect(x: rect.minX + segment * CGFloat(i), y: barY,
                            width: segment, height: 3))
        }
        return used + titleH + metaH + 32
    }

    /// A quiet running head on pages after the first, so a printed guide's
    /// loose pages still say what they belong to.
    private static func drawRunningHead(_ guide: Guide, page: Int, in rect: CGRect,
                                        centred: Bool = false) -> CGFloat {
        let line = NSAttributedString(string: "\(guide.title) · page \(page)", attributes: [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor.gray,
            .paragraphStyle: paragraph(centred),
        ])
        let h = measure(line, width: rect.width)
        line.draw(with: CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        return h + 14
    }

    // MARK: PDF — the two layouts

    /// Flowing: each step takes the room it wants, and breaks to a new page
    /// rather than being split across one.
    private static func drawFlowing(_ guide: Guide, in ctx: CGContext, content: CGRect) {
        var pen = content.maxY
        var pageOpen = false

        func beginPage() { ctx.beginPDFPage(nil); pageOpen = true; pen = content.maxY }
        func endPage() { if pageOpen { ctx.endPDFPage(); pageOpen = false } }
        func reserve(_ height: CGFloat) {
            if !pageOpen { beginPage(); return }
            if pen - height < content.minY { endPage(); beginPage() }
        }

        reserve(headerHeight(guide, width: content.width))
        pen -= drawHeader(guide, in: CGRect(x: content.minX, y: content.minY,
                                            width: content.width, height: pen - content.minY),
                                ctx: ctx)

        for (i, step) in guide.steps.enumerated() {
            let wanted = naturalHeight(step, number: i + 1,
                                       width: content.width, ceiling: content.height)
            reserve(wanted)
            let slot = CGRect(x: content.minX, y: max(pen - wanted, content.minY),
                              width: content.width,
                              height: min(wanted, pen - content.minY))
            drawStep(step, number: i + 1, in: slot, ctx: ctx)
            pen -= wanted
        }

        if !pageOpen { beginPage() }
        endPage()
    }

    /// Fixed: every page gets exactly `perPage` equal slots.
    ///
    /// The header band is reserved on *every* page — the big title on page one,
    /// a running head after that — so each slot is the same height throughout
    /// and the screenshots come out a consistent size. Reserving it only on
    /// page one would make page one's images visibly smaller than the rest.
    /// How many columns a given steps-per-page uses.
    ///
    /// Only four goes to a grid, and it is worth showing the arithmetic because
    /// "more columns means smaller" is the intuition and it is wrong here. On US
    /// Letter with no logo there are about 508 × 612 pt below the header:
    ///
    ///   4 stacked   slot 508 × 140 → after the text, ~104 pt of height left,
    ///               so a 16:10 screenshot lands at about 166 × 104
    ///   2 × 2 grid  cell 245 × 297 → the image is width-constrained instead,
    ///               about 245 × 153
    ///
    /// The grid roughly doubles the picture. Two and three per page stay in one
    /// column: stacked, they keep the full width, and the image comes out bigger
    /// than any side-by-side arrangement of the same count.
    private static func columns(forPerPage perPage: Int) -> Int {
        perPage == 4 ? 2 : 1
    }

    private static func drawFixed(_ guide: Guide, in ctx: CGContext,
                                  content: CGRect, perPage: Int) {
        // Same band on every page — page one holds the title block, later pages
        // a running head — so every slot on every page is the same size.
        let headerBand = max(62, headerHeight(guide, width: content.width))
        let gutter: CGFloat = 18
        let usable = content.height - headerBand

        let cols = columns(forPerPage: perPage)
        let rows = Int(ceil(Double(perPage) / Double(cols)))
        let cellWidth = (content.width - gutter * CGFloat(cols - 1)) / CGFloat(cols)
        let cellHeight = (usable - gutter * CGFloat(rows - 1)) / CGFloat(rows)

        guard cellHeight > 60, cellWidth > 120 else {
            // Too many steps to fit on a page at a legible size; fall back
            // rather than emitting slivers.
            Diag.log("PDF: \(perPage) per page leaves \(Int(cellWidth))x\(Int(cellHeight)) pt "
                     + "per step — falling back to the flowing layout")
            drawFlowing(guide, in: ctx, content: content)
            return
        }

        var page = 0
        for start in stride(from: 0, to: max(guide.count, 1), by: perPage) {
            ctx.beginPDFPage(nil)
            page += 1

            let headerRect = CGRect(x: content.minX, y: content.maxY - headerBand,
                                    width: content.width, height: headerBand)
            if page == 1 {
                _ = drawHeader(guide, in: headerRect, ctx: ctx, centred: true)
            } else {
                _ = drawRunningHead(guide, page: page, in: headerRect, centred: true)
            }

            // Left to right, then down — the order somebody scans a printed
            // sheet, and the order the step numbers have to run in.
            for row in 0..<rows {
                // Tallest caption in this row decides where every picture in it
                // begins, so they line up across the page.
                var reserved: CGFloat = 0
                for column in 0..<cols {
                    let index = start + row * cols + column
                    guard guide.steps.indices.contains(index) else { continue }
                    reserved = max(reserved, textBlockHeight(
                        guide.steps[index], number: index + 1,
                        width: cellWidth, centred: true))
                }

                for column in 0..<cols {
                    let index = start + row * cols + column
                    guard guide.steps.indices.contains(index) else { continue }
                    let x = content.minX + CGFloat(column) * (cellWidth + gutter)
                    let top = content.maxY - headerBand - CGFloat(row) * (cellHeight + gutter)
                    let slot = CGRect(x: x, y: top - cellHeight,
                                      width: cellWidth, height: cellHeight)
                    drawStep(guide.steps[index], number: index + 1, in: slot, ctx: ctx,
                             centred: true, reservedTextHeight: reserved)
                }
            }
            ctx.endPDFPage()
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

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

private extension CGFloat {
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
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - App delegate
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let guide = Guide()
    private let capture = Capture()
    private let prompt = PromptBox()
    private let namePanel = GuideNamePanel()
    private var editor: EditorWindowController?
    private var library: LibraryWindowController?

    private var statusItem: NSStatusItem!
    private var mouseMonitor: Any?
    private var displayTimer: Timer?

    private var isRecording = false
    private var sawFirstFrame = false

    /// Double-click arrives as two separate mouseDown events. Rather than two
    /// near-identical steps, the second one rewrites the first.
    private var eraseAfterShot = false
    private var expandAfterShot = false
    private var lastStep: GuideStep?
    private var lastClickAt = Date.distantPast
    private var lastClickPoint = CGPoint.zero

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

        // ⌃⌥⌘R toggles recording, ⌃⌥⌘E opens the editor. Carbon hotkeys need no
        // permission, so they work even before anything has been granted.
        let mods = UInt32(controlKey | optionKey | cmdKey)
        HotKeyCenter.shared.register(keyCode: 15, modifiers: mods) {   // R
            Task { @MainActor [weak self] in self?.toggleRecording() }
        }
        HotKeyCenter.shared.register(keyCode: 14, modifiers: mods) {   // E
            Task { @MainActor [weak self] in self?.openEditor() }
        }
        HotKeyCenter.shared.register(keyCode: 5, modifiers: mods) {    // G
            Task { @MainActor [weak self] in self?.openLibrary() }
        }
        HotKeyCenter.shared.register(keyCode: 45, modifiers: mods) {   // N
            Task { @MainActor [weak self] in self?.startNewGuide() }
        }

        if CommandLine.arguments.contains("--shot-themes") { shotThemes() }
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
        prompt.commitCurrent()
        capture.stop()
        guide.save()
    }

    // MARK: Recording

    @objc private func toggleRecording() {
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
    private static func suggestedName() -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMd")
        return "Guide — " + f.string(from: Date())
    }

    private func startRecording() {
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

        Diag.log("recording started (guide has \(guide.count) step(s))")
        refreshStatusItem()
    }

    private func stopRecording(openEditor showEditor: Bool) {
        guard isRecording else { return }
        isRecording = false
        prompt.commitCurrent()

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
    private func handleClick(_ event: NSEvent) {
        guard isRecording else { return }
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
    private func captureRegion(for target: ClickTarget, on screen: NSScreen) -> CGRect? {
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
    private func verb(for event: NSEvent) -> String {
        if event.type == .rightMouseDown { return "Right-click" }
        if event.type == .otherMouseDown { return "Middle-click" }

        var parts: [String] = []
        let mods = event.modifierFlags
        if mods.contains(.command) { parts.append("Command") }
        if mods.contains(.shift)   { parts.append("Shift") }
        if mods.contains(.option)  { parts.append("Option") }
        if mods.contains(.control) { parts.append("Control") }
        guard !parts.isEmpty else { return "Click" }
        return parts.joined(separator: "-") + "-click"
    }

    // MARK: Editor

    @objc private func openEditor() {
        if editor == nil {
            let controller = EditorWindowController(guide: guide)
            controller.onNewGuide = { [weak self] in self?.startNewGuide() }
            editor = controller
        }
        editor?.show()
    }

    @objc private func openLibrary() {
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
    private func openGuide(at folder: URL) {
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
    @objc private func startNewGuide() {
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

    @objc private func reopenLastGuide() {
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
    private func buildMainMenu() {
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

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        refreshStatusItem()

        NotificationCenter.default.addObserver(
            forName: Guide.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatusItem() }
            }
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol = isRecording ? "record.circle.fill" : "list.bullet.rectangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Scribe")
        image?.isTemplate = !isRecording
        button.image = image
        button.contentTintColor = isRecording
            ? NSColor(calibratedRed: 0.94, green: 0.16, blue: 0.35, alpha: 1) : nil
        button.title = isRecording
            ? (sawFirstFrame ? " \(guide.count)" : " …")
            : (guide.isEmpty ? "" : " \(guide.count)")
        button.toolTip = isRecording ? "Scribe is recording — ⌃⌥⌘R to stop"
                                     : "Scribe — ⌃⌥⌘R to record"
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let record = NSMenuItem(title: isRecording ? "Stop Recording" : "Start Recording",
                                action: #selector(toggleRecording), keyEquivalent: "r")
        record.keyEquivalentModifierMask = [.control, .option, .command]
        record.target = self
        menu.addItem(record)

        if isRecording && !sawFirstFrame {
            menu.addItem(disabled("   Waiting for the first screen frame…"))
        }

        let edit = NSMenuItem(title: "Open Guide Editor…",
                              action: #selector(openEditor), keyEquivalent: "e")
        edit.keyEquivalentModifierMask = [.control, .option, .command]
        edit.target = self
        edit.isEnabled = true
        menu.addItem(edit)

        let fresh = NSMenuItem(title: "New Guide",
                               action: #selector(startNewGuide), keyEquivalent: "n")
        fresh.keyEquivalentModifierMask = [.control, .option, .command]
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
        all.keyEquivalentModifierMask = [.control, .option, .command]
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
    private func buildCaptureScopeItem() -> NSMenuItem {
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

    @objc private func toggleAskForName() {
        Settings.shared.askForGuideName.toggle()
        Diag.log("ask for guide name = \(Settings.shared.askForGuideName)")
        refreshStatusItem()
    }

    /// "Export Theme ▸" — school branding on exported guides.
    private func buildThemeItem() -> NSMenuItem {
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

    @objc private func setExportTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.exportTheme = ExportTheme.with(id: id)
        Diag.log("export theme set to \(Settings.shared.exportTheme.name)")
        refreshStatusItem()
    }

    @objc private func setCaptureScope(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let scope = CaptureScope.from(storage: raw)
        Settings.shared.captureScope = scope
        Diag.log("capture area set to \(scope.label)")
        refreshStatusItem()
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Screen Recording state is only knowable once a stream has been tried —
    /// CGPreflightScreenCaptureAccess reports stale results for a rebuilt app,
    /// so the menu says "unknown" rather than guessing wrong.
    private func permissionItem(title: String, granted: Bool, unknown: Bool,
                                action: Selector) -> NSMenuItem {
        let mark = unknown ? "–" : (granted ? "✓" : "✗")
        let item = NSMenuItem(title: "\(mark)  \(title)…", action: action, keyEquivalent: "")
        item.target = self
        item.toolTip = unknown
            ? "Checked when a recording starts."
            : (granted ? "Granted." : "Not granted — click to open System Settings.")
        return item
    }

    @objc private func requestScreenAccess() {
        capture.requestAccess()
        openScreenRecordingSettings()
    }

    @objc private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

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
    private func dumpLayout(_ window: NSWindow) {
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
    private static func syntheticFrame() -> CGImage? {
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

    @objc private func openLog() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
            .appendingPathComponent("scribe.log")
        NSWorkspace.shared.open(url)
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
