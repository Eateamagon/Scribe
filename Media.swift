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
// ─────────────────────────────────────────────────────────────────────────────

enum FrameRenderer {

    /// The still, fully rendered. `applyCrop: false` is for the editor's crop
    /// mode, which has to show what is outside the crop to let you move it.
    static func still(_ spec: RenderSpec, applyCrop: Bool = true) -> CGImage? {
        guard let raw = Img.readPNG(spec.imageURL) else { return nil }
        return compose(raw, spec: spec, time: nil, applyCrop: applyCrop)
    }

    /// One GIF frame at `time` seconds into the clip, or nil if the step has
    /// no footage. `maxEdge` downsamples the source first (previews, email).
    static func frame(_ spec: RenderSpec, at time: Double, maxEdge: CGFloat? = nil,
                      applyCrop: Bool = true) -> CGImage? {
        guard let data = spec.clipData, let folder = spec.clipFolder,
              let index = data.frameIndex(at: time),
              var raw = Img.readPNG(folder.appendingPathComponent(data.frames[index].file))
        else { return nil }
        if let maxEdge { raw = Img.downscale(raw, maxEdge: maxEdge) }
        return compose(raw, spec: spec, time: time, applyCrop: applyCrop)
    }

    /// `time == nil` renders the still (highlight); otherwise a GIF frame
    /// (pointer and ripple at that time).
    static func compose(_ raw: CGImage, spec: RenderSpec, time: Double?,
                        applyCrop: Bool) -> CGImage? {
        guard var image = Annotator.redact(raw, with: spec.redactions) else { return nil }
        if let spotlight = spec.spotlight, let dimmed = dim(image, outside: spotlight.rect) {
            image = dimmed
        }
        if time == nil, spec.showHighlight,
           let highlighted = Annotator.annotate(image, click: spec.click, target: spec.target,
                                                number: spec.number) {
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

    /// Darkens everything outside `norm`.
    static func dim(_ image: CGImage, outside norm: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = Img.bitmap(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let hole = Geo.drawRect(norm, in: w, h)
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: w, height: h))
        path.addRoundedRect(in: hole, cornerWidth: max(w, h) / 200, cornerHeight: max(w, h) / 200)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)
        return ctx.makeImage()
    }

    /// First version: the spotlit area at `zoom`× in a framed inset, in the
    /// corner farthest from it.
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
        let source = Geo.drawRect(area, in: w, h).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard source.width > 4, source.height > 4,
              let piece = image.cropping(to: CGRect(x: source.minX, y: h - source.maxY,
                                                    width: source.width, height: source.height)
                                            .integral),
              let ctx = Img.bitmap(width: image.width, height: image.height)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var size = CGSize(width: source.width * spotlight.zoom, height: source.height * spotlight.zoom)
        let limit = CGSize(width: w * 0.45, height: h * 0.45)
        let fit = min(limit.width / size.width, limit.height / size.height, 1)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        let margin = max(w, h) / 60
        let centre: CGPoint
        if let inset = spotlight.inset {
            centre = CGPoint(x: inset.x * w, y: (1 - inset.y) * h)
        } else {
            // Opposite corner from the spotlit area.
            let right = source.midX < w / 2
            let top = source.midY < h / 2
            centre = CGPoint(x: right ? w - margin - size.width / 2 : margin + size.width / 2,
                             y: top ? h - margin - size.height / 2 : margin + size.height / 2)
        }
        let frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                           width: size.width, height: size.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -margin / 4), blur: margin / 2,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(frame.insetBy(dx: -margin / 5, dy: -margin / 5))
        ctx.restoreGState()
        ctx.interpolationQuality = .high
        ctx.draw(piece, in: frame)
        ctx.setStrokeColor(Annotator.accent)
        ctx.setLineWidth(max(2, max(w, h) / 500))
        ctx.stroke(frame.insetBy(dx: -margin / 5, dy: -margin / 5))
        return ctx.makeImage()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Pointer overlay
// ─────────────────────────────────────────────────────────────────────────────

enum PointerOverlay {
    /// Seconds a click ripple stays visible.
    static let rippleDuration = 0.45

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
            ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
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
        while picked.count > limit {
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
}

enum GifEncoder {
    /// Baseline encoder on ImageIO. Frames are (image, seconds to show it).
    /// Consecutive identical frames should already have been merged by the
    /// caller; this only writes what it is given.
    static func encode(_ frames: [(image: CGImage, delay: Double)]) -> Data? {
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
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Media preparation (off-main)
// ─────────────────────────────────────────────────────────────────────────────

enum MediaPreparer {
    /// Renders and encodes a GIF for `spec` at `preset`. nil if the step has
    /// no footage or the result will not fit the preset's budget.
    static func gif(_ spec: RenderSpec, preset: GifPreset) -> Data? {
        guard spec.hasFootage, let clip = spec.clip else { return nil }
        var frames: [(image: CGImage, delay: Double)] = []
        for t in ClipTimeline.times(for: clip, fps: preset.fps) {
            guard let image = FrameRenderer.frame(spec, at: t, maxEdge: nil) else { continue }
            frames.append((Img.downscale(image, maxEdge: preset.maxEdge), 1 / preset.fps))
        }
        guard let data = GifEncoder.encode(frames) else { return nil }
        if let budget = preset.maxBytes, data.count > budget { return nil }
        return data
    }

    /// Async wrapper for callers on the main actor.
    static func gifAsync(_ spec: RenderSpec, preset: GifPreset) async -> Data? {
        await Task.detached(priority: .userInitiated) { gif(spec, preset: preset) }.value
    }

    /// Key frames for the PDF filmstrip, fully rendered.
    static func filmstrip(_ spec: RenderSpec, maxEdge: CGFloat = 900) -> [CGImage] {
        guard spec.hasFootage, let clip = spec.clip, let data = spec.clipData else { return [] }
        return KeyFrames.pick(clip, data).compactMap {
            FrameRenderer.frame(spec, at: $0, maxEdge: maxEdge * 1.5)
                .map { Img.downscale($0, maxEdge: maxEdge) }
        }
    }
}
