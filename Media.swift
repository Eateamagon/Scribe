//
//  Scribe — GIF clips, crop/spotlight model, off-main rendering and encoding
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Clip model
//
// A GIF step is an ordinary step (still screenshot, click, target, text) plus
// footage. The footage lives in its own folder beside the screenshots:
//
//   shot-004.png          the still — pre-click frame of the first click
//   gif-004/clip.json     ClipData: frames, pointer track, clicks (immutable)
//   gif-004/frame-0001.jpg …
//
// The still and every frame are the same region at the same pixel size, so
// every normalised coordinate on the step (click, target, covers, markup,
// crop, spotlight) means the same thing on both. That is what lets a step
// flip between GIF and screenshot without converting anything.
//
// What the user can change about the clip (trim, which frame is the still,
// whether the pointer shows) is `GifClip`, stored in guide.json with the step.
// ─────────────────────────────────────────────────────────────────────────────

enum StepMedia: String, Sendable {
    case screenshot, gif
}

/// One captured frame. `time` is seconds from the start of the clip.
struct ClipFrame: Codable, Sendable, Equatable {
    var file: String
    var time: Double
}

/// Where the pointer was. The capture stream hides the real cursor (a cursor
/// in every still screenshot would sit on top of what was clicked), so GIFs
/// draw a synthetic one from this track.
struct PointerSample: Codable, Sendable, Equatable {
    var time: Double
    /// 0…1, top-left origin, against the clip region.
    var point: CGPoint
}

/// A click made while the clip was recording.
struct ClipClick: Codable, Sendable, Equatable {
    var time: Double
    var point: CGPoint
    var target: CGRect?
    var label: String
    var verb: String
}

/// The immutable part of a recording, written once to `gif-NNN/clip.json`.
struct ClipData: Codable, Sendable, Equatable {
    var frames: [ClipFrame]
    var pointer: [PointerSample]
    var clicks: [ClipClick]
    /// Seconds from Fn-down to Fn-up (or the cap).
    var duration: Double
    /// Pixel size of every frame (and of the still).
    var pixelSize: CGSize
    /// Size of the captured region in screen points — the synthetic cursor is
    /// drawn at a constant *point* size, so it needs to know the scale.
    var regionPoints: CGSize

    static let fileName = "clip.json"

    static func load(from folder: URL) -> ClipData? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName))
        else { return nil }
        return try? JSONDecoder().decode(ClipData.self, from: data)
    }

    @discardableResult
    func write(to folder: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: folder.appendingPathComponent(ClipData.fileName))) != nil
    }

    /// The newest frame at or before `time` — the screen as it looked then.
    /// ScreenCaptureKit only delivers a frame when pixels change, so a quiet
    /// stretch is one frame held, not a gap.
    func frameIndex(at time: Double) -> Int? {
        guard !frames.isEmpty else { return nil }
        var best = 0
        for (i, f) in frames.enumerated() where f.time <= time + 0.0005 { best = i }
        return best
    }

    /// Pointer position at `time`, interpolated between samples.
    func pointer(at time: Double) -> CGPoint? {
        guard let first = pointer.first else { return nil }
        if time <= first.time { return first.point }
        for (a, b) in zip(pointer, pointer.dropFirst()) where b.time >= time {
            let span = b.time - a.time
            guard span > 0 else { return b.point }
            let t = CGFloat((time - a.time) / span)
            return CGPoint(x: a.point.x + (b.point.x - a.point.x) * t,
                           y: a.point.y + (b.point.y - a.point.y) * t)
        }
        return pointer.last?.point
    }
}

/// The editable part of a clip, stored on the step in guide.json.
struct GifClip: Sendable, Equatable {
    /// Folder name beside the screenshots, e.g. "gif-004".
    var folder: String
    /// Seconds into the clip. The GIF plays trimStart…trimEnd.
    var trimStart: Double
    var trimEnd: Double
    /// Draw the synthetic pointer and click ripples.
    var showPointer: Bool = true

    var length: Double { max(trimEnd - trimStart, 0) }

    var dictionary: [String: Any] {
        ["folder": folder, "trimStart": trimStart, "trimEnd": trimEnd,
         "showPointer": showPointer]
    }

    static func from(_ d: [String: Any]) -> GifClip? {
        guard let folder = d["folder"] as? String,
              let start = d["trimStart"] as? Double,
              let end = d["trimEnd"] as? Double
        else { return nil }
        return GifClip(folder: folder, trimStart: start, trimEnd: end,
                       showPointer: d["showPointer"] as? Bool ?? true)
    }

    /// Default trim: a second of lead-in before the first click, a second and
    /// a half after the last so the result of the click is visible.
    static func defaultTrim(for data: ClipData) -> (start: Double, end: Double) {
        guard let first = data.clicks.first, let last = data.clicks.last else {
            return (0, data.duration)
        }
        return (max(0, first.time - 1.0), min(data.duration, last.time + 1.5))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Crop and spotlight
// ─────────────────────────────────────────────────────────────────────────────

/// Draws the eye to one area. `.dim` darkens everything outside `rect`;
/// `.magnify` additionally shows `rect` enlarged in an inset.
struct Spotlight: Sendable, Equatable {
    enum Mode: String, Sendable { case dim, magnify }

    /// 0…1, top-left, against the uncropped stored image — like every other
    /// piece of step geometry.
    var rect: CGRect
    var mode: Mode
    /// Magnification for `.magnify`.
    var zoom: CGFloat = 2
    /// Centre of the magnifier inset, 0…1 against the *output* (cropped)
    /// image. nil = placed automatically in the emptiest corner.
    var inset: CGPoint?

    var dictionary: [String: Any] {
        var d: [String: Any] = ["x": rect.minX, "y": rect.minY, "w": rect.width,
                                "h": rect.height, "mode": mode.rawValue, "zoom": zoom]
        if let inset { d["insetX"] = inset.x; d["insetY"] = inset.y }
        return d
    }

    static func from(_ d: [String: Any]) -> Spotlight? {
        guard let x = d["x"] as? CGFloat, let y = d["y"] as? CGFloat,
              let w = d["w"] as? CGFloat, let h = d["h"] as? CGFloat
        else { return nil }
        var inset: CGPoint?
        if let ix = d["insetX"] as? CGFloat, let iy = d["insetY"] as? CGFloat {
            inset = CGPoint(x: ix, y: iy)
        }
        return Spotlight(rect: CGRect(x: x, y: y, width: w, height: h),
                         mode: Mode(rawValue: d["mode"] as? String ?? "") ?? .dim,
                         zoom: d["zoom"] as? CGFloat ?? 2,
                         inset: inset)
    }
}

enum RectCoding {
    static func dictionary(_ r: CGRect) -> [String: Any] {
        ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
    }
    static func rect(_ d: Any?) -> CGRect? {
        guard let d = d as? [String: Any],
              let x = d["x"] as? CGFloat, let y = d["y"] as? CGFloat,
              let w = d["w"] as? CGFloat, let h = d["h"] as? CGFloat
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Render spec
//
// `GuideStep` is @MainActor. Rendering a 150-frame GIF on the main thread
// freezes the editor, so every render takes a value snapshot instead — all it
// needs, nothing it can mutate — and runs wherever it likes.
// ─────────────────────────────────────────────────────────────────────────────

struct RenderSpec: Sendable {
    var imageURL: URL
    var number: Int
    var click: CGPoint
    var target: CGRect?
    var showHighlight: Bool
    var redactions: [Redaction]
    var markups: [Markup]
    var crop: CGRect?
    var spotlight: Spotlight?
    var media: StepMedia
    var clip: GifClip?
    var clipFolder: URL?
    var clipData: ClipData?

    /// A GIF step whose footage actually loaded.
    var hasFootage: Bool { clip != nil && clipData != nil && !(clipData?.frames.isEmpty ?? true) }
    var rendersAsGIF: Bool { media == .gif && hasFootage }
}

extension GuideStep {
    func renderSpec(number: Int) -> RenderSpec {
        RenderSpec(imageURL: imageURL, number: number, click: click, target: target,
                   showHighlight: showHighlight, redactions: redactions, markups: markups,
                   crop: crop, spotlight: spotlight, media: media, clip: gif,
                   clipFolder: clipFolderURL, clipData: clipData)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Frame renderer
//
// The one place pixels are produced. Order, and why:
//
//   redact        covers first, so nothing drawn later can sit under one
//   spotlight dim before the highlight, so the red box is not dimmed
//   highlight     the still only — GIF frames get pointer + click ripple
//   markup        the user's own drawing always on top of the automatic mark
//   crop          last, so no geometry needs remapping
//   magnifier     after crop, positioned in the output
//
// The first two depend only on the source picture, so they are the "static"
// passes: a GIF render caches their result per source frame, because a quiet
// stretch of footage is one captured frame shown for many output frames.
//
// Nothing here touches AppKit state — text is Core Text, every bitmap is a
// local CGContext — so all of it is safe on any queue.
// ─────────────────────────────────────────────────────────────────────────────

enum FrameRenderer {

    /// The still, fully rendered. `applyCrop: false` is for the editor's crop
    /// mode, which has to show what is outside the crop to let you move it.
    /// `maxEdge` bounds the result's longest edge; the source is shrunk
    /// *first*, so every pass runs at output size rather than at 1800 px.
    static func still(_ spec: RenderSpec, applyCrop: Bool = true,
                      maxEdge: CGFloat? = nil) -> CGImage? {
        guard var raw = Img.readPNG(spec.imageURL) else { return nil }
        if let maxEdge {
            let size = CGSize(width: raw.width, height: raw.height)
            let scale = sourceScale(size, spec: spec, maxEdge: maxEdge, applyCrop: applyCrop)
            if scale < 1 { raw = Img.downscale(raw, maxEdge: max(size.width, size.height) * scale) }
        }
        return compose(raw, spec: spec, time: nil, applyCrop: applyCrop)
    }

    /// One GIF frame at `time` seconds into the clip, or nil if the step has
    /// no footage. `maxEdge` bounds the result's longest edge (after any
    /// crop); the source frame is decoded straight to the size that needs.
    static func frame(_ spec: RenderSpec, at time: Double, maxEdge: CGFloat? = nil,
                      applyCrop: Bool = true) -> CGImage? {
        frame(spec, at: time, maxEdge: maxEdge, applyCrop: applyCrop, cache: nil)
    }

    /// As above, reusing the static passes from `cache` when the source frame
    /// is the one it already holds.
    static func frame(_ spec: RenderSpec, at time: Double, maxEdge: CGFloat?,
                      applyCrop: Bool, cache: StaticPassCache?) -> CGImage? {
        guard let data = spec.clipData, let folder = spec.clipFolder,
              let index = data.frameIndex(at: time)
        else { return nil }
        let key = StaticPassCache.Key(source: index, maxEdge: maxEdge, applyCrop: applyCrop)
        let base: CGImage
        if let hit = cache?.image(for: key) {
            base = hit
        } else {
            let url = folder.appendingPathComponent(data.frames[index].file)
            guard let raw = loadSource(url, spec: spec, maxEdge: maxEdge, applyCrop: applyCrop),
                  let prepared = staticPasses(raw, spec: spec)
            else { return nil }
            cache?.store(prepared, for: key)
            base = prepared
        }
        return dynamicPasses(base, spec: spec, time: time, applyCrop: applyCrop)
    }

    /// How far to shrink a source of `size` pixels so the output — the crop,
    /// when one applies — comes out no longer than `maxEdge`. Never enlarges.
    static func sourceScale(_ size: CGSize, spec: RenderSpec, maxEdge: CGFloat,
                            applyCrop: Bool) -> CGFloat {
        var shown = size
        if applyCrop, let crop = spec.crop {
            shown = CGSize(width: size.width * crop.width, height: size.height * crop.height)
        }
        let longest = max(shown.width, shown.height)
        guard longest > 0, maxEdge > 0 else { return 1 }
        return min(1, maxEdge / longest)
    }

    private static func loadSource(_ url: URL, spec: RenderSpec, maxEdge: CGFloat?,
                                   applyCrop: Bool) -> CGImage? {
        guard let maxEdge, let size = Img.pixelSize(of: url) else { return Img.readPNG(url) }
        let scale = sourceScale(size, spec: spec, maxEdge: maxEdge, applyCrop: applyCrop)
        guard scale < 1 else { return Img.readPNG(url) }
        let longest = max(size.width, size.height) * scale
        // JPEG only decodes cheaply at 1/2, 1/4, 1/8 — measured on a
        // 1600 px frame, 600 px comes straight out in 4 ms against 8 ms for
        // decode-then-shrink, while 1200 px is no faster that way (15 ms
        // either way; the full decode is the cost). So the direct route only
        // when it can skip work.
        if scale <= 0.5 { return Img.read(url, longestEdge: longest) }
        return Img.readPNG(url).map { Img.downscale($0, maxEdge: longest) }
    }

    /// `time == nil` renders the still (highlight); otherwise a GIF frame
    /// (pointer and ripple at that time).
    static func compose(_ raw: CGImage, spec: RenderSpec, time: Double?,
                        applyCrop: Bool) -> CGImage? {
        guard let base = staticPasses(raw, spec: spec) else { return nil }
        return dynamicPasses(base, spec: spec, time: time, applyCrop: applyCrop)
    }

    /// Redact, then dim: everything that depends only on the source picture.
    static func staticPasses(_ raw: CGImage, spec: RenderSpec) -> CGImage? {
        guard var image = Annotator.redact(raw, with: spec.redactions) else { return nil }
        if let spotlight = spec.spotlight, let dimmed = dim(image, outside: spotlight.rect) {
            image = dimmed
        }
        return image
    }

    /// Highlight or pointer, markup, crop, magnifier.
    static func dynamicPasses(_ base: CGImage, spec: RenderSpec, time: Double?,
                              applyCrop: Bool) -> CGImage? {
        var image = base
        if time == nil, spec.showHighlight,
           let highlighted = Annotator.annotate(image, click: spec.click, target: spec.target,
                                                number: spec.number,
                                                visible: applyCrop ? spec.crop : nil) {
            image = highlighted
        }
        if let time, let clip = spec.clip, clip.showPointer, let data = spec.clipData,
           let withPointer = PointerOverlay.draw(on: image, data: data, at: time) {
            image = withPointer
        }
        if let drawn = Annotator.draw(spec.markups, on: image) { image = drawn }
        if applyCrop, let crop = spec.crop, let cropped = cropNormalized(image, to: crop) {
            image = cropped
        }
        if let spotlight = spec.spotlight, spotlight.mode == .magnify,
           let magnified = magnify(image, spec: spec, spotlight: spotlight, applyCrop: applyCrop) {
            image = magnified
        }
        return image
    }

    static func cropNormalized(_ image: CGImage, to norm: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let r = CGRect(x: norm.minX * w, y: norm.minY * h,
                       width: norm.width * w, height: norm.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard r.width >= 8, r.height >= 8 else { return nil }
        return image.cropping(to: r)
    }

    /// Darkens everything outside `norm`, and rims the hole with a soft white
    /// edge. Without the rim a dim over a dark UI reads as a rendering fault;
    /// with it, as somebody deliberately pointing.
    static func dim(_ image: CGImage, outside norm: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = Img.bitmap(width: image.width, height: image.height) else { return nil }
        let whole = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: whole)
        let longest = max(w, h)
        let hole = Geo.drawRect(norm, in: w, h)
        guard hole.width >= 2, hole.height >= 2 else { return ctx.makeImage() }
        // CGPath asserts if a corner is more than half the side.
        let radius = min(longest / 200, hole.width / 2, hole.height / 2)
        let rim = CGPath(roundedRect: hole, cornerWidth: radius, cornerHeight: radius,
                         transform: nil)
        let path = CGMutablePath()
        path.addRect(whole)
        path.addPath(rim)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)

        // A faint wide glow under a crisp hairline: soft, but still an edge
        // after the GIF palette has had its way with the glow.
        let hairline = max(1, longest / 1400)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
        ctx.setLineWidth(hairline * 3)
        ctx.addPath(rim); ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.8))
        ctx.setLineWidth(hairline)
        ctx.addPath(rim); ctx.strokePath()
        return ctx.makeImage()
    }

    /// The spotlit area at `zoom`× in a framed inset. Placed at `inset` when
    /// the user has put it somewhere; otherwise in whichever corner is
    /// farthest from the area and does not cover it — a magnifier sitting on
    /// top of the thing it magnifies defeats itself.
    ///
    /// No connector line: the dim hole's rim already marks the source, and a
    /// line across a busy screenshot is one more thing to read past.
    static func magnify(_ image: CGImage, spec: RenderSpec, spotlight: Spotlight,
                        applyCrop: Bool) -> CGImage? {
        // Where the spotlight sits in the output image's own 0…1 space.
        var area = spotlight.rect
        if applyCrop, let crop = spec.crop {
            area = CGRect(x: (area.minX - crop.minX) / crop.width,
                          y: (area.minY - crop.minY) / crop.height,
                          width: area.width / crop.width, height: area.height / crop.height)
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let whole = CGRect(x: 0, y: 0, width: w, height: h)
        let source = Geo.drawRect(area, in: w, h).intersection(whole)
        guard !source.isNull, source.width > 4, source.height > 4,
              // CGImage cropping is top-left origin; `source` is CG bottom-left.
              let piece = image.cropping(to: CGRect(x: source.minX, y: h - source.maxY,
                                                    width: source.width, height: source.height)
                                            .integral),
              let ctx = Img.bitmap(width: image.width, height: image.height)
        else { return image }
        ctx.draw(image, in: whole)

        let margin = max(w, h) / 60
        let frame = magnifierFrame(source: source, spotlight: spotlight, in: whole)
        let size = frame.size
        let corner = min(margin * 0.45, size.width / 2, size.height / 2)
        let outline = CGPath(roundedRect: frame, cornerWidth: corner, cornerHeight: corner,
                             transform: nil)

        // Shadow first, from a filled plate, so the picture itself stays crisp.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -margin / 6), blur: margin / 1.4,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(outline); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(outline); ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(piece, in: frame)
        ctx.restoreGState()

        ctx.setStrokeColor(Annotator.accent)
        ctx.setLineWidth(max(1.5, max(w, h) / 600))
        ctx.addPath(outline); ctx.strokePath()
        return ctx.makeImage()
    }

    /// Where the magnifier goes, in CG (bottom-left) coordinates.
    /// Where the magnifier inset goes, in CG pixels (bottom-left) of an
    /// output of `bounds` size, for a spotlit `source` rect in the same space.
    /// The editor hit-tests the inset with this same function — two copies of
    /// the arithmetic drifted apart once already.
    static func magnifierFrame(source: CGRect, spotlight: Spotlight, in bounds: CGRect) -> CGRect {
        let margin = max(bounds.width, bounds.height) / 60
        let zoom = max(spotlight.zoom, 1)
        var size = CGSize(width: source.width * zoom, height: source.height * zoom)
        let limit = CGSize(width: bounds.width * 0.45, height: bounds.height * 0.45)
        let fit = min(limit.width / size.width, limit.height / size.height, 1)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        return insetFrame(size: size, avoiding: source, in: bounds, margin: margin,
                          requested: spotlight.inset)
    }

    static func insetFrame(size: CGSize, avoiding source: CGRect, in bounds: CGRect,
                           margin: CGFloat, requested: CGPoint?) -> CGRect {
        func clamped(centre: CGPoint) -> CGRect {
            let x = min(max(centre.x - size.width / 2, bounds.minX + margin),
                        bounds.maxX - margin - size.width)
            let y = min(max(centre.y - size.height / 2, bounds.minY + margin),
                        bounds.maxY - margin - size.height)
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        if let requested {
            // `inset` is 0…1 top-left, like every other stored coordinate.
            return clamped(centre: CGPoint(x: bounds.minX + requested.x * bounds.width,
                                           y: bounds.maxY - requested.y * bounds.height))
        }
        let xs = [bounds.minX, bounds.midX - size.width / 2 - margin,
                  bounds.maxX - size.width - margin * 2]
        let ys = [bounds.minY, bounds.midY - size.height / 2 - margin,
                  bounds.maxY - size.height - margin * 2]
        // Corners before edge midpoints: they read as "an inset", the middle
        // of an edge reads as a pop-up.
        var candidates: [(frame: CGRect, corner: Bool)] = []
        for (i, x) in xs.enumerated() {
            for (j, y) in ys.enumerated() where !(i == 1 && j == 1) {
                let frame = clamped(centre: CGPoint(x: x + margin + size.width / 2,
                                                    y: y + margin + size.height / 2))
                candidates.append((frame, i != 1 && j != 1))
            }
        }
        let keepOut = source.insetBy(dx: -margin / 2, dy: -margin / 2)
        func score(_ c: (frame: CGRect, corner: Bool)) -> CGFloat {
            let overlap = c.frame.intersection(keepOut)
            let covered = overlap.isNull ? 0 : overlap.width * overlap.height
            let distance = hypot(c.frame.midX - source.midX, c.frame.midY - source.midY)
            // Covering the source outweighs any distance; corners win ties.
            return distance - covered * 1000 + (c.corner ? margin * 4 : 0)
        }
        return candidates.max { score($0) < score($1) }?.frame
            ?? clamped(centre: CGPoint(x: bounds.maxX - size.width / 2, y: bounds.minY + size.height / 2))
    }
}

/// The static passes (redact + dim) of the source frame a render last used.
/// One per render and not shared between threads: consecutive output frames
/// either reuse the same source or move on to the next, so one entry is the
/// whole benefit — and a larger cache of full-size bitmaps is the memory
/// problem `Img.maxEdge` exists to avoid.
final class StaticPassCache {
    struct Key: Equatable {
        var source: Int
        var maxEdge: CGFloat?
        var applyCrop: Bool
    }
    private var key: Key?
    private var image: CGImage?
    private(set) var hits = 0
    private(set) var misses = 0

    func image(for key: Key) -> CGImage? {
        if key == self.key, let image { hits += 1; return image }
        misses += 1
        return nil
    }

    func store(_ image: CGImage, for key: Key) {
        self.key = key
        self.image = image
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Pointer overlay
// ─────────────────────────────────────────────────────────────────────────────

enum PointerOverlay {
    /// Seconds a click ripple stays visible.
    static let rippleDuration = 0.45

    /// The arrow's colours. Exact entries in every GIF palette, so the cursor
    /// never comes out as the nearest muddy grey.
    static let fill = CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    static let outline = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    /// Whether a click ripple is on screen at `time`.
    static func isRippling(_ data: ClipData, at time: Double) -> Bool {
        data.clicks.contains { time >= $0.time && time - $0.time < rippleDuration }
    }

    /// Draws the synthetic arrow cursor, plus a ripple for any click in the
    /// last `rippleDuration` seconds. Vector, not NSCursor's image: thread-safe
    /// and identical at every size.
    static func draw(on image: CGImage, data: ClipData, at time: Double) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = Img.bitmap(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Pixels per screen point, so the cursor is its real on-screen size.
        let scale = data.regionPoints.width > 0 ? w / data.regionPoints.width : 1

        for click in data.clicks where time >= click.time && time - click.time < rippleDuration {
            let progress = CGFloat((time - click.time) / rippleDuration)
            let c = Geo.drawPoint(click.point, in: w, h)
            let radius = (8 + 22 * progress) * scale
            ctx.setStrokeColor(Annotator.accent.copy(alpha: 0.9 * (1 - progress)) ?? Annotator.accent)
            ctx.setLineWidth(3 * scale)
            ctx.strokeEllipse(in: CGRect(x: c.x - radius, y: c.y - radius,
                                         width: radius * 2, height: radius * 2))
        }

        if let p = data.pointer(at: time) {
            let tip = Geo.drawPoint(p, in: w, h)
            let s = scale
            // Classic arrow, tip at (0,0), pointing up-left; y is up in CG.
            let pts: [CGPoint] = [(0, 0), (0, -17), (4, -13), (7, -20), (10, -19),
                                  (7, -12), (12, -12)]
                .map { CGPoint(x: tip.x + $0.0 * s, y: tip.y + $0.1 * s) }
            let path = CGMutablePath()
            path.addLines(between: pts)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(1.4 * s)
            ctx.setLineJoin(.round)
            ctx.drawPath(using: .fillStroke)
        }
        return ctx.makeImage()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Timeline and key frames
// ─────────────────────────────────────────────────────────────────────────────

enum ClipTimeline {
    /// Output frame times across the trimmed range at `fps`.
    static func times(for clip: GifClip, fps: Double) -> [Double] {
        guard clip.length > 0, fps > 0 else { return [clip.trimStart] }
        let step = 1 / fps
        var out: [Double] = []
        var t = clip.trimStart
        while t < clip.trimEnd - 0.0001 { out.append(t); t += step }
        return out.isEmpty ? [clip.trimStart] : out
    }
}

enum KeyFrames {
    /// Moments worth printing: just after each click (so the ripple shows),
    /// plus the start and the end, deduplicated and thinned to `limit`.
    static func pick(_ clip: GifClip, _ data: ClipData, limit: Int = 4) -> [Double] {
        var candidates = [clip.trimStart]
        candidates += data.clicks.map { $0.time + 0.15 }
            .filter { $0 >= clip.trimStart && $0 <= clip.trimEnd }
        candidates.append(max(clip.trimStart, clip.trimEnd - 0.05))
        var picked: [Double] = []
        for t in candidates.sorted() where !picked.contains(where: { abs($0 - t) < 0.3 }) {
            picked.append(t)
        }
        while picked.count > max(limit, 1) {
            // Drop the interior moment closest to its neighbour.
            var worst = 1, gap = Double.infinity
            for i in 1..<(picked.count - 1) {
                let g = min(picked[i] - picked[i - 1], picked[i + 1] - picked[i])
                if g < gap { gap = g; worst = i }
            }
            picked.remove(at: worst)
        }
        return picked
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GIF encoding
//
// Written by hand because ImageIO's GIF writer is built for photographs: every
// frame full-canvas with its own local palette. Screen footage is the opposite
// case — one small thing moves over a big still picture — and paying for the
// whole canvas eighty times is what makes those files enormous.
//
// So, per clip:
//   · one global palette: a 15-bit histogram sampled from about every fifth
//     frame, median-cut to 255 colours, plus index 255 reserved as transparent
//   · the annotation red, white, near-black and the cursor's colours forced in
//     as exact entries — a highlight quantised to "nearest brownish pink" reads
//     as a different colour from the one in the stills
//   · no dithering: dither noise on flat UI is ugly and defeats both the delta
//     frames and LZW
//   · delta frames: only the bounding box of what changed is written, and
//     unchanged pixels inside it are transparent (disposal 1 keeps the rest)
//   · identical consecutive frames merged, delays summed
// ─────────────────────────────────────────────────────────────────────────────

struct GifPreset: Sendable {
    var maxEdge: CGFloat
    var fps: Double
    /// nil = no budget.
    var maxBytes: Int?

    static let web = GifPreset(maxEdge: 1200, fps: 10, maxBytes: nil)
    static let email = GifPreset(maxEdge: 600, fps: 8, maxBytes: 1_500_000)
    static let markdown = GifPreset(maxEdge: 1200, fps: 10, maxBytes: nil)
    static let preview = GifPreset(maxEdge: 1000, fps: 10, maxBytes: nil)

    /// What to try, in order, to get under `maxBytes`: as asked, then fewer
    /// frames, then fewer frames *and* smaller. Frame rate goes first because
    /// a tutorial GIF is mostly held frames and survives it; size goes second
    /// because text is what stops being readable.
    var budgetLadder: [GifPreset] {
        guard maxBytes != nil else { return [self] }
        var slower = self
        slower.fps = fps * 0.75
        var smaller = slower
        smaller.maxEdge = maxEdge * 0.8
        return [self, slower, smaller]
    }
}

enum GifEncoder {
    /// Frames are (image, seconds to show it). Every frame is drawn onto a
    /// canvas the size of the first.
    static func encode(_ frames: [(image: CGImage, delay: Double)]) -> Data? {
        encode(frames, forcing: [])
    }

    /// As `encode(_:)`, with extra colours guaranteed an exact palette entry
    /// (a step's cover and drawing colours).
    static func encode(_ frames: [(image: CGImage, delay: Double)],
                       forcing extra: [CGColor]) -> Data? {
        guard let first = frames.first,
              let raster = Raster(width: first.image.width, height: first.image.height)
        else { return nil }
        let histogram = Histogram()
        let samples = Set(Histogram.sampleIndices(count: frames.count))
        for (i, frame) in frames.enumerated() {
            if samples.contains(i) {
                raster.draw(frame.image)
                histogram.add(raster)
            } else {
                histogram.addCoverage(frame.image, fullPixels: raster.count)
            }
        }
        let palette = Palette(histogram, forcing: extra)
        guard let writer = Writer(width: first.image.width, height: first.image.height,
                                  palette: palette)
        else { return nil }
        for frame in frames { writer.add(frame.image, delay: frame.delay) }
        return writer.finish()
    }

    /// The ImageIO encoder this replaced, kept as the size baseline the media
    /// self-test measures against.
    static func encodeImageIO(_ frames: [(image: CGImage, delay: Double)]) -> Data? {
        guard !frames.isEmpty else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString,
                                                          frames.count, nil)
        else { return nil }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(dest, frame.image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: max(frame.delay, 0.02),
                    kCGImagePropertyGIFUnclampedDelayTime: max(frame.delay, 0.02),
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: Raster

    /// A reusable 8-bit sRGB RGBX buffer a frame is drawn into before it is
    /// quantised. sRGB because a GIF has no colour profile and every viewer
    /// assumes sRGB; drawing converts whatever space the frame was in.
    final class Raster {
        let width: Int
        let height: Int
        var count: Int { width * height }
        /// Memory order R, G, B, X — so as a little-endian UInt32 red is the
        /// low byte.
        let pixels: UnsafeMutablePointer<UInt32>
        private let context: CGContext

        init?(width: Int, height: Int) {
            guard width > 0, height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB)
            else { return nil }
            let buffer = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
            buffer.initialize(repeating: 0, count: width * height)
            guard let ctx = CGContext(data: buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { buffer.deallocate(); return nil }
            self.width = width
            self.height = height
            pixels = buffer
            context = ctx
            // `.copy` replaces every pixel, so nothing from the last frame can
            // show through; `.high` only matters for a frame of the wrong size.
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .high
        }

        deinit { pixels.deallocate() }

        func draw(_ image: CGImage) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        /// 15-bit histogram / lookup key: five bits each of R, G, B.
        @inline(__always)
        static func key(_ p: UInt32) -> Int {
            Int(((p >> 3) & 0x1F) << 10 | ((p >> 11) & 0x1F) << 5 | ((p >> 19) & 0x1F))
        }

        /// `colors` exactly as the renderers produce them: filled into the
        /// DeviceRGB bitmap every pass uses, then drawn through this raster.
        /// Computing them from the CGColor components instead is off by the
        /// colour conversion, and "exact entry" would be exact for nobody.
        static func rendered(_ colors: [CGColor]) -> [(r: UInt8, g: UInt8, b: UInt8)] {
            guard !colors.isEmpty, let ctx = Img.bitmap(width: colors.count, height: 1)
            else { return [] }
            for (i, color) in colors.enumerated() {
                ctx.setFillColor(color)
                ctx.fill(CGRect(x: i, y: 0, width: 1, height: 1))
            }
            guard let image = ctx.makeImage(),
                  let raster = Raster(width: colors.count, height: 1)
            else { return [] }
            raster.draw(image)
            return (0..<colors.count).map { i in
                let p = raster.pixels[i]
                return (UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF))
            }
        }
    }

    // MARK: Histogram

    final class Histogram {
        static let bins = 32768
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: bins)
        let sums = UnsafeMutablePointer<Int>.allocate(capacity: bins * 3)

        init() {
            counts.initialize(repeating: 0, count: Histogram.bins)
            sums.initialize(repeating: 0, count: Histogram.bins * 3)
        }

        deinit { counts.deallocate(); sums.deallocate() }

        /// About every fifth frame, never more than a dozen — a long clip is
        /// the same screen for longer, not more colours.
        static func sampleIndices(count: Int) -> [Int] {
            guard count > 0 else { return [] }
            let stride = max(5, Int((Double(count) / 12).rounded(.up)))
            var picks = Array(Swift.stride(from: 0, to: count, by: stride))
            if picks.last != count - 1 { picks.append(count - 1) }
            return picks
        }

        /// Longest edge of the coverage pass over the frames `sampleIndices`
        /// skips.
        static let coverageEdge: CGFloat = 240
        private var coverage: Raster?

        func add(_ raster: Raster, weight: Int = 1) {
            let pixels = raster.pixels, counts = self.counts, sums = self.sums
            for i in 0..<raster.count {
                let p = pixels[i]
                let k = Raster.key(p)
                counts[k] += weight
                sums[k * 3] += Int(p & 0xFF) * weight
                sums[k * 3 + 1] += Int((p >> 8) & 0xFF) * weight
                sums[k * 3 + 2] += Int((p >> 16) & 0xFF) * weight
            }
        }

        /// Adds a frame the full-size sample skipped, shrunk to
        /// `coverageEdge`. It is there for its *colours*: a menu open for
        /// three frames between two samples would otherwise get no palette
        /// entry at all and come out in the nearest wrong colour. Each small
        /// pixel is weighted by the area it stands for, so every frame counts
        /// once whichever way it was sampled.
        func addCoverage(_ image: CGImage, fullPixels: Int) {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let scale = min(1, Histogram.coverageEdge / max(w, h, 1))
            let sw = max(Int((w * scale).rounded()), 1), sh = max(Int((h * scale).rounded()), 1)
            if coverage?.width != sw || coverage?.height != sh {
                coverage = Raster(width: sw, height: sh)
            }
            guard let raster = coverage else { return }
            raster.draw(image)
            add(raster, weight: max(1, Int((Double(fullPixels) / Double(raster.count)).rounded())))
        }
    }

    // MARK: Palette

    /// ≤ 255 colours plus the transparent index, and a lazily filled
    /// 32 K lookup table from 15-bit colour to palette index.
    final class Palette {
        static let transparent: UInt8 = 255
        /// Built into every palette: the annotation red, white, and the two
        /// near-blacks (cursor fill, markup black).
        static let builtIn: [(r: UInt8, g: UInt8, b: UInt8)] = Raster.rendered([
            Annotator.accent, PointerOverlay.outline, PointerOverlay.fill,
            MarkupColor.black.cgColor,
        ])

        private(set) var r: [Int32] = []
        private(set) var g: [Int32] = []
        private(set) var b: [Int32] = []
        var count: Int { r.count }
        private let lut = UnsafeMutablePointer<UInt16>.allocate(capacity: Histogram.bins)
        /// Mean colour of each histogram bin that was seen, packed 0xBBGGRR,
        /// or UInt32.max — used as the bin's representative for the lookup.
        private let means = UnsafeMutablePointer<UInt32>.allocate(capacity: Histogram.bins)

        deinit { lut.deallocate(); means.deallocate() }

        init(_ histogram: Histogram, forcing extra: [CGColor]) {
            lut.initialize(repeating: .max, count: Histogram.bins)
            means.initialize(repeating: .max, count: Histogram.bins)

            // Forced entries first, deduplicated.
            var forced: [(r: UInt8, g: UInt8, b: UInt8)] = []
            for c in Palette.builtIn + Raster.rendered(extra)
            where !forced.contains(where: { $0 == c }) && forced.count < 32 {
                forced.append(c)
            }
            var forcedBins = Set<Int>()
            for c in forced {
                forcedBins.insert(Raster.key(UInt32(c.r) | UInt32(c.g) << 8 | UInt32(c.b) << 16))
            }

            var entries: [MedianCut.Entry] = []
            for k in 0..<Histogram.bins where histogram.counts[k] > 0 {
                let n = histogram.counts[k]
                let mr = Double(histogram.sums[k * 3]) / Double(n)
                let mg = Double(histogram.sums[k * 3 + 1]) / Double(n)
                let mb = Double(histogram.sums[k * 3 + 2]) / Double(n)
                means[k] = UInt32(mr.rounded()) | UInt32(mg.rounded()) << 8
                    | UInt32(mb.rounded()) << 16
                // The forced colour's own bin would only produce a near-copy
                // of it; leave the slot for something else.
                if forcedBins.contains(k) { continue }
                entries.append(MedianCut.Entry(r: mr, g: mg, b: mb, weight: Double(n)))
            }

            let cut = MedianCut.palette(entries, colors: 255 - forced.count)
            for c in forced { r.append(Int32(c.r)); g.append(Int32(c.g)); b.append(Int32(c.b)) }
            for c in cut {
                r.append(Int32(min(max(c.r.rounded(), 0), 255)))
                g.append(Int32(min(max(c.g.rounded(), 0), 255)))
                b.append(Int32(min(max(c.b.rounded(), 0), 255)))
            }
            if r.isEmpty { r = [0]; g = [0]; b = [0] }
        }

        /// The 768-byte global colour table, padded to 256 entries.
        var table: [UInt8] {
            var out = [UInt8](repeating: 0, count: 768)
            for i in 0..<count {
                out[i * 3] = UInt8(r[i]); out[i * 3 + 1] = UInt8(g[i]); out[i * 3 + 2] = UInt8(b[i])
            }
            return out
        }

        /// Maps a raster to palette indices.
        func quantize(_ pixels: UnsafePointer<UInt32>, count n: Int,
                      into out: UnsafeMutablePointer<UInt8>) {
            // Screen footage is long runs of one colour, so remembering the
            // last pixel skips most lookups outright.
            var lastPixel: UInt32 = 0xFFFF_FFFF
            var lastIndex: UInt8 = 0
            let lut = self.lut
            for i in 0..<n {
                let p = pixels[i] & 0x00FF_FFFF
                if p == lastPixel { out[i] = lastIndex; continue }
                let k = Raster.key(p)
                var v = lut[k]
                if v == .max { v = UInt16(nearest(bin: k)); lut[k] = v }
                lastPixel = p
                lastIndex = UInt8(truncatingIfNeeded: v)
                out[i] = lastIndex
            }
        }

        /// Nearest entry to the bin's mean colour (or its centre, if the
        /// sampled frames never hit it), weighted toward green the way the
        /// eye is. Brute force over ≤ 255 entries, once per bin actually used.
        private func nearest(bin k: Int) -> Int {
            let cr: Int32, cg: Int32, cb: Int32
            let m = means[k]
            if m != .max {
                cr = Int32(m & 0xFF); cg = Int32((m >> 8) & 0xFF); cb = Int32((m >> 16) & 0xFF)
            } else {
                cr = Int32((k >> 10) & 0x1F) << 3 | 4
                cg = Int32((k >> 5) & 0x1F) << 3 | 4
                cb = Int32(k & 0x1F) << 3 | 4
            }
            var best = 0
            var bestDistance = Int32.max
            for i in 0..<count {
                let dr = r[i] - cr, dg = g[i] - cg, db = b[i] - cb
                let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                if d < bestDistance { bestDistance = d; best = i }
            }
            return best
        }
    }

    // MARK: Median cut

    enum MedianCut {
        struct Entry {
            var r: Double, g: Double, b: Double
            var weight: Double
        }

        private struct Box {
            var lo: Int, hi: Int
            var error: Double
            var axis: Int
            var mean: (r: Double, g: Double, b: Double)
        }

        /// Splits the box with the largest squared error each time, along its
        /// widest (perceptually weighted) axis at the weighted median. Error
        /// rather than population, so a big flat background gets one colour
        /// and the gradients and anti-aliasing get the rest.
        static func palette(_ input: [Entry], colors: Int) -> [(r: Double, g: Double, b: Double)] {
            guard !input.isEmpty, colors > 0 else { return [] }
            var entries = input
            let weights: [Double] = [2, 4, 3]

            func makeBox(_ lo: Int, _ hi: Int) -> Box {
                var n = 0.0, sr = 0.0, sg = 0.0, sb = 0.0
                for i in lo..<hi {
                    let e = entries[i]
                    n += e.weight; sr += e.r * e.weight; sg += e.g * e.weight; sb += e.b * e.weight
                }
                let mean = (r: sr / n, g: sg / n, b: sb / n)
                var vr = 0.0, vg = 0.0, vb = 0.0
                for i in lo..<hi {
                    let e = entries[i]
                    vr += (e.r - mean.r) * (e.r - mean.r) * e.weight
                    vg += (e.g - mean.g) * (e.g - mean.g) * e.weight
                    vb += (e.b - mean.b) * (e.b - mean.b) * e.weight
                }
                let axisError = [vr * weights[0], vg * weights[1], vb * weights[2]]
                let axis = axisError.firstIndex(of: axisError.max()!) ?? 0
                return Box(lo: lo, hi: hi, error: hi - lo > 1 ? axisError.reduce(0, +) : 0,
                           axis: axis, mean: mean)
            }

            var boxes = [makeBox(0, entries.count)]
            while boxes.count < colors {
                guard let pick = boxes.indices.max(by: { boxes[$0].error < boxes[$1].error }),
                      boxes[pick].error > 0
                else { break }
                let box = boxes[pick]
                let axis = box.axis
                entries[box.lo..<box.hi].sort {
                    axis == 0 ? $0.r < $1.r : axis == 1 ? $0.g < $1.g : $0.b < $1.b
                }
                var total = 0.0
                for i in box.lo..<box.hi { total += entries[i].weight }
                var running = 0.0
                var split = box.lo + 1
                for i in box.lo..<(box.hi - 1) {
                    running += entries[i].weight
                    split = i + 1
                    if running >= total / 2 { break }
                }
                boxes[pick] = makeBox(box.lo, split)
                boxes.append(makeBox(split, box.hi))
            }
            return boxes.map(\.mean)
        }
    }

    // MARK: LZW

    /// GIF's variable-length LZW: 8-bit minimum code size, clear code first,
    /// table reset (with a clear) when it reaches 4096 codes.
    final class LZW {
        private static let clear = 256, end = 257
        /// Child code for (prefix code, next byte), 0 = none. Dense rather
        /// than hashed: 2 MB, and one load per pixel.
        private let table = UnsafeMutablePointer<UInt16>.allocate(capacity: 4096 * 256)
        /// Slots set since the last reset, so a reset clears only those.
        private let used = UnsafeMutablePointer<Int32>.allocate(capacity: 4096)
        private var usedCount = 0

        init() { table.initialize(repeating: 0, count: 4096 * 256) }
        deinit { table.deallocate(); used.deallocate() }


        private struct Bits {
            var bytes: [UInt8] = []
            var acc: UInt64 = 0
            var count = 0

            @inline(__always)
            mutating func put(_ code: Int, _ size: Int) {
                acc |= UInt64(code) << UInt64(count)
                count += size
                while count >= 8 {
                    bytes.append(UInt8(truncatingIfNeeded: acc))
                    acc >>= 8
                    count -= 8
                }
            }

            mutating func flush() {
                if count > 0 { bytes.append(UInt8(truncatingIfNeeded: acc)) }
                acc = 0; count = 0
            }
        }

        /// Appends the minimum-code-size byte, the data sub-blocks and the
        /// block terminator for `n` indices.
        func encode(_ input: UnsafePointer<UInt8>, count n: Int, into out: inout [UInt8]) {
            // Locals, so the hot loop is loads and stores rather than
            // property accesses through `self`.
            let table = self.table, used = self.used
            var usedCount = self.usedCount
            func reset() {
                for i in 0..<usedCount { table[Int(used[i])] = 0 }
                usedCount = 0
            }
            defer { self.usedCount = usedCount }

            var bits = Bits()
            bits.bytes.reserveCapacity(n / 3 + 64)
            reset()
            var size = 9
            var next = 258
            bits.put(LZW.clear, size)
            if n > 0 {
                var prefix = Int(input[0])
                var i = 1
                while i < n {
                    let k = Int(input[i])
                    i += 1
                    let slot = prefix << 8 | k
                    let child = table[slot]
                    if child != 0 { prefix = Int(child); continue }
                    bits.put(prefix, size)
                    if next < 4096 {
                        table[slot] = UInt16(next)
                        used[usedCount] = Int32(slot)
                        usedCount += 1
                        next += 1
                        // The decoder adds each entry one code later than we
                        // do, so it widens when *its* table reaches the
                        // power of two — one step behind ours, hence `>`.
                        if next > 1 << size && size < 12 { size += 1 }
                    } else {
                        bits.put(LZW.clear, size)
                        reset()
                        size = 9
                        next = 258
                    }
                    prefix = k
                }
                bits.put(prefix, size)
                // Reading that last code makes the decoder add one more entry,
                // which may widen the end code.
                if next == 1 << size && size < 12 { size += 1 }
            }
            bits.put(LZW.end, size)
            bits.flush()

            out.append(8)
            var start = 0
            while start < bits.bytes.count {
                let length = min(255, bits.bytes.count - start)
                out.append(UInt8(length))
                out.append(contentsOf: bits.bytes[start..<(start + length)])
                start += length
            }
            out.append(0)
        }
    }

    // MARK: Writer

    /// Streams frames into a GIF: quantise, diff against the frame on
    /// screen, write only the changed box. A frame is held back until the
    /// next one proves it different, so identical frames merge into one
    /// longer delay instead of costing a descriptor each.
    final class Writer {
        let width: Int
        let height: Int
        let palette: Palette
        private let raster: Raster
        private var current: UnsafeMutablePointer<UInt8>
        private var previous: UnsafeMutablePointer<UInt8>
        private var region: UnsafeMutablePointer<UInt8>
        private let lzw = LZW()
        private var out: [UInt8] = []
        private var hasPrevious = false
        /// Image descriptor + data for the frame not yet written, its delay
        /// so far, and whether it uses the transparent index.
        private var pending: [UInt8] = []
        private var pendingDelay = 0.0
        private var pendingTransparent = false
        private var exactEnd = 0.0
        private var writtenCentiseconds = 0
        private(set) var framesWritten = 0
        private(set) var framesMerged = 0

        var byteCount: Int { out.count + pending.count }

        init?(width: Int, height: Int, palette: Palette) {
            guard width > 0, height > 0, width <= 65535, height <= 65535,
                  let raster = Raster(width: width, height: height)
            else { return nil }
            self.width = width
            self.height = height
            self.palette = palette
            self.raster = raster
            let n = width * height
            current = .allocate(capacity: n)
            previous = .allocate(capacity: n)
            region = .allocate(capacity: n)
            current.initialize(repeating: 0, count: n)
            previous.initialize(repeating: 0, count: n)
            region.initialize(repeating: 0, count: n)

            out.reserveCapacity(n / 2)
            out.append(contentsOf: Array("GIF89a".utf8))
            appendShort(width); appendShort(height)
            // Global colour table present, 8-bit colour resolution, 256 entries.
            out.append(0xF7); out.append(0); out.append(0)
            out.append(contentsOf: palette.table)
            // NETSCAPE2.0: loop forever.
            out.append(contentsOf: [0x21, 0xFF, 0x0B])
            out.append(contentsOf: Array("NETSCAPE2.0".utf8))
            out.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        }

        deinit { current.deallocate(); previous.deallocate(); region.deallocate() }

        private func appendShort(_ v: Int) {
            out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        }

        func add(_ image: CGImage, delay: Double) {
            raster.draw(image)
            palette.quantize(raster.pixels, count: raster.count, into: current)
            let delay = max(delay, 0)

            guard hasPrevious else {
                pending = descriptor(x: 0, y: 0, w: width, h: height, delta: false)
                pendingDelay = delay
                pendingTransparent = false
                hasPrevious = true
                swapBuffers()
                return
            }
            settleNoise()
            guard let box = changedBox() else {
                pendingDelay += delay
                framesMerged += 1
                return
            }
            flush()
            pending = descriptor(x: box.minX, y: box.minY, w: box.width, h: box.height, delta: true)
            pendingDelay = delay
            pendingTransparent = true
            swapBuffers()
        }

        /// How much closer (in the palette's weighted distance) a new index
        /// has to be before a pixel is rewritten — about three levels a
        /// channel. Anything less is JPEG noise in the captured frames.
        static let noiseMargin: Int32 = 80

        /// Keeps the on-screen index wherever the new one is barely better.
        ///
        /// The frames are JPEGs, so a still area comes back a level or two
        /// different every frame, and near a boundary between two palette
        /// entries that flips the index. Left alone those flips spread every
        /// delta box across the screen and make flat areas shimmer. Comparing
        /// against the colour actually *displayed* means nothing can drift:
        /// the moment the real colour moves away, the pixel updates.
        private func settleNoise() {
            let w = width
            let pixels = raster.pixels
            let margin = Writer.noiseMargin
            palette.r.withUnsafeBufferPointer { r in
                palette.g.withUnsafeBufferPointer { g in
                    palette.b.withUnsafeBufferPointer { b in
                        for y in 0..<height where memcmp(current + y * w, previous + y * w, w) != 0 {
                            let row = y * w
                            for x in 0..<w {
                                let i = row + x
                                let now = Int(current[i]), shown = Int(previous[i])
                                if now == shown { continue }
                                let p = pixels[i]
                                let pr = Int32(p & 0xFF), pg = Int32((p >> 8) & 0xFF)
                                let pb = Int32((p >> 16) & 0xFF)
                                var dr = r[now] - pr, dg = g[now] - pg, db = b[now] - pb
                                let dNow = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                                dr = r[shown] - pr; dg = g[shown] - pg; db = b[shown] - pb
                                let dShown = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                                if dShown <= dNow + margin { current[i] = previous[i] }
                            }
                        }
                    }
                }
            }
        }

        /// What was just quantised becomes the frame on screen.
        private func swapBuffers() {
            let shown = current
            current = previous
            previous = shown
        }

        func finish() -> Data {
            flush()
            out.append(0x3B)
            return Data(out)
        }

        /// Writes the held frame with its accumulated delay. Delays are in
        /// centiseconds with the rounding error carried forward, so a clip of
        /// 0.125 s frames still adds up to its real length; 2 cs is the floor
        /// because browsers play anything shorter as 10 cs.
        private func flush() {
            guard !pending.isEmpty else { return }
            exactEnd += pendingDelay
            let target = Int((exactEnd * 100).rounded())
            let cs = min(max(2, target - writtenCentiseconds), 65535)
            writtenCentiseconds += cs
            // Graphic control extension: disposal 1 (leave in place), plus
            // the transparent index for delta frames.
            out.append(contentsOf: [0x21, 0xF9, 0x04,
                                    UInt8(1 << 2 | (pendingTransparent ? 1 : 0)),
                                    UInt8(cs & 0xFF), UInt8((cs >> 8) & 0xFF),
                                    Palette.transparent, 0x00])
            out.append(contentsOf: pending)
            pending = []
            framesWritten += 1
        }

        /// Bounding box (in top-left pixel coordinates) of indices that differ
        /// from the frame on screen, or nil if none do.
        private func changedBox() -> (minX: Int, minY: Int, width: Int, height: Int)? {
            let w = width
            var top = -1, bottom = -1
            for y in 0..<height where memcmp(current + y * w, previous + y * w, w) != 0 {
                if top < 0 { top = y }
                bottom = y
            }
            guard top >= 0 else { return nil }
            var left = w, right = -1
            for y in top...bottom {
                let c = current + y * w, p = previous + y * w
                var x = 0
                while x < left && c[x] == p[x] { x += 1 }
                if x < left { left = x }
                var z = w - 1
                while z > right && c[z] == p[z] { z -= 1 }
                if z > right { right = z }
            }
            guard right >= left else { return nil }
            return (left, top, right - left + 1, bottom - top + 1)
        }

        /// Image descriptor and LZW data for one rectangle of `current`. A
        /// delta frame writes unchanged pixels as transparent: the long runs
        /// that makes are most of what LZW compresses away.
        private func descriptor(x: Int, y: Int, w: Int, h: Int, delta: Bool) -> [UInt8] {
            var n = 0
            for row in y..<(y + h) {
                let c = current + row * width + x
                if delta {
                    let p = previous + row * width + x
                    for col in 0..<w {
                        region[n] = c[col] == p[col] ? Palette.transparent : c[col]
                        n += 1
                    }
                } else {
                    (region + n).update(from: c, count: w)
                    n += w
                }
            }
            var bytes: [UInt8] = [0x2C]
            bytes.reserveCapacity(n / 3 + 32)
            for v in [x, y, w, h] { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF)) }
            bytes.append(0)   // no local table, not interlaced
            lzw.encode(region, count: n, into: &bytes)
            return bytes
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Media preparation (off-main)
//
// Everything here takes a `RenderSpec` value and touches no main-actor state,
// so it runs on whatever queue calls it.
// ─────────────────────────────────────────────────────────────────────────────

enum MediaPreparer {

    /// One output frame of a GIF: shown from `time` for `delay` seconds,
    /// rendered from source frame `source`.
    struct PlannedFrame: Sendable {
        var time: Double
        var source: Int
        var delay: Double
    }

    /// What a GIF render did, for the self-test and the log.
    struct GifReport: Sendable {
        var data: Data?
        /// The rung of the budget ladder that produced `data` (or the last tried).
        var preset: GifPreset
        var attempts = 0
        var planned = 0
        var rendered = 0
        var written = 0
        var renderSeconds = 0.0
        var encodeSeconds = 0.0
    }

    /// Renders and encodes a GIF for `spec` at `preset`. nil if the step has
    /// no footage or the result will not fit the preset's budget even after
    /// the ladder — the caller then falls back to the still.
    static func gif(_ spec: RenderSpec, preset: GifPreset) -> Data? {
        gifReport(spec, preset: preset).data
    }

    /// Async wrapper for callers on the main actor.
    static func gifAsync(_ spec: RenderSpec, preset: GifPreset) async -> Data? {
        await Task.detached(priority: .userInitiated) { gif(spec, preset: preset) }.value
    }

    /// `gif(_:preset:)` with the working shown.
    static func gifReport(_ spec: RenderSpec, preset: GifPreset) -> GifReport {
        var report = GifReport(data: nil, preset: preset)
        guard spec.hasFootage else { return report }
        for rung in preset.budgetLadder {
            report.attempts += 1
            report.preset = rung
            if let data = encode(spec, preset: rung, budget: preset.maxBytes, report: &report) {
                report.data = data
                return report
            }
        }
        return report
    }

    /// The still at export size, fully rendered.
    static func still(_ spec: RenderSpec, maxEdge: CGFloat?) -> CGImage? {
        FrameRenderer.still(spec, applyCrop: true, maxEdge: maxEdge)
    }

    /// Output frames across the trim at `fps`, with runs that would render
    /// identically merged up front: same source frame, pointer where it was,
    /// no ripple animating. Cheaper than rendering them and letting the
    /// encoder notice they match.
    static func plan(_ spec: RenderSpec, fps: Double) -> [PlannedFrame] {
        guard let clip = spec.clip, let data = spec.clipData else { return [] }
        let times = ClipTimeline.times(for: clip, fps: fps)
        var out: [PlannedFrame] = []
        var lastPointer: CGPoint?
        var lastRippling = false
        for (i, t) in times.enumerated() {
            let end = i + 1 < times.count ? times[i + 1] : max(clip.trimEnd, t)
            let delay = end - t
            guard let source = data.frameIndex(at: t) else { continue }
            let pointer = clip.showPointer ? data.pointer(at: t) : nil
            let rippling = clip.showPointer && PointerOverlay.isRippling(data, at: t)
            if let last = out.last, last.source == source, !rippling, !lastRippling,
               samePlace(pointer, lastPointer) {
                out[out.count - 1].delay += delay
                continue
            }
            out.append(PlannedFrame(time: t, source: source, delay: delay))
            lastPointer = pointer
            lastRippling = rippling
        }
        return out
    }

    /// Within about half a pixel at 1200 px — the same picture.
    private static func samePlace(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.x - b.x) < 0.0004 && abs(a.y - b.y) < 0.0004
        default: return false
        }
    }

    /// The planned frames, rendered. For measuring and for the ImageIO
    /// baseline; `gif` itself streams instead of holding them all.
    static func renderFrames(_ spec: RenderSpec, preset: GifPreset) -> [(image: CGImage, delay: Double)] {
        let frames = plan(spec, fps: preset.fps)
        let images = renderConcurrently(spec, frames, Array(frames.indices), maxEdge: preset.maxEdge)
        return frames.indices.compactMap { i in images[i].map { (image: $0, delay: frames[i].delay) } }
    }

    /// Colours a step's own covers and drawings use — given exact palette
    /// entries, so a blue arrow in the still is the same blue in the GIF.
    static func specColors(_ spec: RenderSpec) -> [CGColor] {
        var colors = Set(spec.markups.map(\.color))
        for r in spec.redactions where r.style == .solid { colors.insert(r.color) }
        return MarkupColor.allCases.filter { colors.contains($0) }.map(\.cgColor)
    }

    /// One rung of the ladder: palette from a sample of the planned frames
    /// (kept, so they are not rendered twice) plus a thumbnail pass over the
    /// rest, then every frame streamed through the writer in batches. Gives
    /// up as soon as the output passes `budget`.
    private static func encode(_ spec: RenderSpec, preset: GifPreset, budget: Int?,
                               report: inout GifReport) -> Data? {
        let frames = plan(spec, fps: preset.fps)
        report.planned = frames.count
        guard !frames.isEmpty else { return nil }
        var renderTime = 0.0
        func render(_ indices: [Int], maxEdge: CGFloat) -> [Int: CGImage] {
            let started = Date()
            defer { renderTime += Date().timeIntervalSince(started) }
            return renderConcurrently(spec, frames, indices, maxEdge: maxEdge)
        }

        let sampleIndices = GifEncoder.Histogram.sampleIndices(count: frames.count)
        var sampled = render(sampleIndices, maxEdge: preset.maxEdge)
        report.rendered += sampled.count
        guard let first = sampled[0] ?? sampled.values.first,
              let raster = GifEncoder.Raster(width: first.width, height: first.height)
        else { return nil }
        // Every other frame at thumbnail size, for colours the full-size
        // sample would miss; see `Histogram.addCoverage`.
        let rest = frames.indices.filter { sampled[$0] == nil }
        let thumbnails = render(rest, maxEdge: GifEncoder.Histogram.coverageEdge)

        let encodeStarted = Date()
        let histogram = GifEncoder.Histogram()
        for i in rest { if let image = thumbnails[i] { histogram.addCoverage(image, fullPixels: raster.count) } }
        for i in sampleIndices { if let image = sampled[i] { raster.draw(image); histogram.add(raster) } }
        let palette = GifEncoder.Palette(histogram, forcing: specColors(spec))
        guard let writer = GifEncoder.Writer(width: first.width, height: first.height,
                                             palette: palette)
        else { return nil }
        var encodeTime = Date().timeIntervalSince(encodeStarted)
        func finishReport() {
            report.written = writer.framesWritten
            report.renderSeconds += renderTime
            report.encodeSeconds += encodeTime
        }

        // Batches of a few frames per core: parallel rendering, bounded
        // memory, and the writer still sees frames strictly in order.
        let batch = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        var start = 0
        while start < frames.count {
            let range = start..<min(start + batch, frames.count)
            let rendered = render(range.filter { sampled[$0] == nil }, maxEdge: preset.maxEdge)
            report.rendered += rendered.count
            for i in range {
                guard let image = sampled.removeValue(forKey: i) ?? rendered[i] else { continue }
                let started = Date()
                writer.add(image, delay: frames[i].delay)
                encodeTime += Date().timeIntervalSince(started)
                if let budget, writer.byteCount > budget {
                    finishReport()
                    return nil
                }
            }
            start = range.upperBound
        }
        let started = Date()
        let data = writer.finish()
        encodeTime += Date().timeIntervalSince(started)
        finishReport()
        if let budget, data.count > budget { return nil }
        return data
    }

    /// Renders `indices` of `frames` across all cores. Consecutive frames of
    /// the same source go to one worker, so they share its static-pass cache
    /// — a pointer moving over a still screen is one decode, not one each.
    static func renderConcurrently(_ spec: RenderSpec, _ frames: [PlannedFrame], _ indices: [Int],
                                   maxEdge: CGFloat) -> [Int: CGImage] {
        guard !indices.isEmpty else { return [:] }
        var groups: [[Int]] = []
        for i in indices {
            if let last = groups.last?.last, last == i - 1, frames[last].source == frames[i].source {
                groups[groups.count - 1].append(i)
            } else {
                groups.append([i])
            }
        }
        let slots = UnsafeMutableBufferPointer<CGImage?>.allocate(capacity: indices.count)
        slots.initialize(repeating: nil)
        defer { slots.deinitialize(); slots.deallocate() }
        var offsets: [Int] = []
        var offset = 0
        for group in groups { offsets.append(offset); offset += group.count }
        // Each worker writes only its own slots.
        DispatchQueue.concurrentPerform(iterations: groups.count) { g in
            let cache = StaticPassCache()
            for (k, i) in groups[g].enumerated() {
                slots[offsets[g] + k] = FrameRenderer.frame(spec, at: frames[i].time, maxEdge: maxEdge,
                                                           applyCrop: true, cache: cache)
            }
        }
        var out: [Int: CGImage] = [:]
        for (g, group) in groups.enumerated() {
            for (k, i) in group.enumerated() { out[i] = slots[offsets[g] + k] }
        }
        return out
    }

    /// When the PDF filmstrip samples the clip: `KeyFrames.pick` over the trim.
    static func filmstripTimes(_ spec: RenderSpec) -> [Double] {
        guard spec.hasFootage, let clip = spec.clip, let data = spec.clipData else { return [] }
        return KeyFrames.pick(clip, data)
    }

    /// Key frames for the PDF filmstrip, fully rendered.
    static func filmstrip(_ spec: RenderSpec, maxEdge: CGFloat = 900) -> [CGImage] {
        let cache = StaticPassCache()
        return filmstripTimes(spec).compactMap {
            FrameRenderer.frame(spec, at: $0, maxEdge: maxEdge, applyCrop: true, cache: cache)
        }
    }
}
