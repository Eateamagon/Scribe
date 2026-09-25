//
//  Scribe — self-tests for rendering, crop, spotlight and GIF encoding
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers

/// Carries a result back from a background queue. Only ever written by the
/// one background block and read after the semaphore says it is done.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

extension AppDelegate {
    /// `--selftest-media`. Owned by the media work; see Media.swift.
    ///
    /// Builds a guide with the shared synthetic GIF step plus a plain
    /// screenshot step, then proves each media claim at the pixel level:
    /// the encoder's output decodes, keeps its covers in every frame and beats
    /// ImageIO on size; crop, dim and magnify land where they should; a
    /// background render matches the main-thread one byte for byte; the new
    /// fields survive guide.json; flattening reaches the footage; the email
    /// budget gives up rather than overshooting.
    func runMediaSelfTest() {
        let guide = Guide()
        guide.title = "Media Self Test"
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            if !ok {
                failures.append(label)
                Diag.log("SELFTEST-MEDIA FAILED: \(label)")
            }
        }
        func log(_ line: String) { Diag.log("SELFTEST-MEDIA \(line)") }
        func done() {
            if failures.isEmpty {
                Diag.log("SELFTEST-MEDIA PASSED — \(guide.folder.path)")
            } else {
                Diag.log("SELFTEST-MEDIA FAILED: \(failures.count) check(s): "
                         + failures.joined(separator: "; "))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
        }

        let click = CGPoint(x: 0.30, y: 0.415)
        let target = CGRect(x: 0.22, y: 0.38, width: 0.16, height: 0.07)
        guard let gifStep = Self.appendSyntheticGifStep(to: guide),
              let screen = Self.syntheticFrame(),
              let plain = guide.append(image: screen, click: click, target: target,
                                       appName: "Finder", windowTitle: "Plain Window",
                                       elementLabel: "New Folder", verb: "Click"),
              let clip = gifStep.gif
        else {
            check(false, "could not build the fixture guide")
            done(); return
        }
        let folder = guide.folder
        func write(_ image: CGImage?, _ name: String) {
            if let image { _ = Img.writePNG(image, to: folder.appendingPathComponent(name)) }
        }

        // A solid blue cover across the moving block's path, so every frame
        // has something underneath it that must not show.
        let cover = CGRect(x: 0.45, y: 0.68, width: 0.15, height: 0.14)
        let coverCentre = CGPoint(x: cover.midX, y: cover.midY)
        guide.addRedaction(Redaction(rect: cover, style: .solid, color: .blue), at: 0)
        let blue = Self.renderedColor(MarkupColor.blue.cgColor)
        log("fonts: badge=\(Self.fontName(Annotator.TextLine.bold)) "
            + "label=\(Self.fontName(Annotator.TextLine.semibold)) "
            + "appkit=\(NSFont.systemFont(ofSize: 20, weight: .semibold).fontName)")

        // (a) (b) (j) The web GIF: decodes, adds up, keeps the cover.
        let spec = gifStep.renderSpec(number: 1)
        let started = Date()
        let report = MediaPreparer.gifReport(spec, preset: .web)
        let wall = Date().timeIntervalSince(started)
        guard let gif = report.data else {
            check(false, "web GIF returned nil")
            done(); return
        }
        try? gif.write(to: folder.appendingPathComponent("media-web.gif"))
        let decoded = Self.decodeGIF(gif)
        let total = decoded.delays.reduce(0, +)
        log(String(format: "(a) web gif %d bytes, %d frames decoded (%d planned, %d rendered), "
                   + "delays %.3fs vs trim %.3fs", gif.count, decoded.frames.count,
                   report.planned, report.rendered, total, clip.length))
        check(decoded.frames.count > 1, "(a) decoded frame count \(decoded.frames.count)")
        check(abs(total - clip.length) <= 0.05, "(a) delays \(total) vs trim \(clip.length)")

        var coverMisses = 0
        for image in decoded.frames {
            guard let c = Img.sample(image, at: coverCentre), Self.near(c, blue, 14)
            else { coverMisses += 1; continue }
        }
        log("(b) cover colour at cover centre in \(decoded.frames.count - coverMisses)"
            + "/\(decoded.frames.count) decoded frames")
        check(coverMisses == 0, "(b) cover missing from \(coverMisses) frame(s)")

        // Decoded against freshly rendered: proves the delta frames,
        // transparency and LZW reconstruct the picture, not just a pixel.
        let planned = MediaPreparer.plan(spec, fps: GifPreset.web.fps)
        var worstMean = 0.0, worstOutliers = 0.0
        var start = clip.trimStart
        for (k, image) in decoded.frames.enumerated() {
            let source = planned.last { $0.time <= start + 0.006 } ?? planned[0]
            start += decoded.delays[k]
            guard let rendered = FrameRenderer.frame(spec, at: source.time,
                                                     maxEdge: GifPreset.web.maxEdge)
            else { check(false, "(b) render for comparison"); break }
            let diff = Self.difference(image, rendered)
            worstMean = max(worstMean, diff.mean)
            worstOutliers = max(worstOutliers, diff.outliers)
        }
        log(String(format: "(b) decoded vs rendered: worst mean |Δ| %.2f, worst outliers %.3f%%",
                   worstMean, worstOutliers * 100))
        check(worstMean < 3 && worstOutliers < 0.005, "(b) decoded frames drift from the render")
        if let first = decoded.frames.first, let last = decoded.frames.last {
            write(first, "gif-decoded-first.png")
            write(decoded.frames[decoded.frames.count / 2], "gif-decoded-middle.png")
            write(last, "gif-decoded-last.png")
        }

        let single = Date()
        for i in 0..<10 { _ = FrameRenderer.frame(spec, at: 0.5 + Double(i) * 0.2, maxEdge: 1200) }
        let perFrame = Date().timeIntervalSince(single) * 100
        log(String(format: "(j) web gif: %.1f ms per frame on one thread; in the pipeline %d frames "
                   + "rendered in %.0f ms (all cores, incl. palette thumbnails), %.0f ms encode, "
                   + "%.0f ms wall", perFrame, report.rendered, report.renderSeconds * 1000,
                   report.encodeSeconds * 1000, wall * 1000))

        // (c) Same frames through both encoders.
        let frames = MediaPreparer.renderFrames(spec, preset: .web)
        let custom = GifEncoder.encode(frames, forcing: MediaPreparer.specColors(spec))
        let imageIO = GifEncoder.encodeImageIO(frames)
        log("(c) \(frames.count) frames: custom \(custom?.count ?? -1) bytes, "
            + "ImageIO \(imageIO?.count ?? -1) bytes")
        check((custom?.count ?? .max) < (imageIO?.count ?? 0), "(c) custom encoder not smaller")

        // (a) Encoder bookkeeping on hand-made frames: identical neighbours
        // merge, 0.125 s delays carry their rounding and still add up to
        // exactly 1 s, and the forced colours are exact palette entries.
        let solids = [MarkupColor.white, .blue, .green, .orange].map { color -> CGImage? in
            guard let ctx = Img.bitmap(width: 64, height: 40) else { return nil }
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
            ctx.setFillColor(Annotator.accent)
            ctx.fill(CGRect(x: 8, y: 8, width: 12, height: 12))
            return ctx.makeImage()
        }.compactMap { $0 }
        if solids.count == 4 {
            let sequence = [0, 0, 1, 2, 2, 2, 3, 0].map { (image: solids[$0], delay: 0.125) }
            let merged = GifEncoder.encode(sequence).map(Self.decodeGIF)
            let cs = merged?.delays.map { Int(($0 * 100).rounded()) } ?? []
            let table = GifEncoder.encode(sequence).map { [UInt8]($0.prefix(13 + 768).dropFirst(13)) } ?? []
            let exact = GifEncoder.Palette.builtIn.allSatisfy { c in
                stride(from: 0, to: table.count, by: 3).contains {
                    table[$0] == c.r && table[$0 + 1] == c.g && table[$0 + 2] == c.b
                }
            }
            log("(a) 8 frames with 3 repeats -> \(merged?.frames.count ?? -1) frames, delays \(cs) cs; "
                + "forced colours exact in palette: \(exact)")
            check(merged?.frames.count == 5 && cs == [25, 13, 37, 13, 12], "(a) merge / carried delays")
            check(exact, "(a) forced colours missing from the palette")
            let quick = GifEncoder.encode([(solids[0], 0.004), (solids[1], 0.004)]).map(Self.decodeGIF)
            check(quick?.delays.map { Int(($0 * 100).rounded()) } == [2, 2], "(a) 2 cs floor")
        } else {
            check(false, "(a) solid fixtures")
        }

        // (j) The performance target: 40 distinct 1200×750 frames.
        let forty: [(image: CGImage, delay: Double)] = (0..<40).compactMap { i in
            FrameRenderer.frame(spec, at: Double(i) / 10, maxEdge: 1200).map { ($0, 0.1) }
        }
        let encodeStarted = Date()
        let fortyGIF = GifEncoder.encode(forty)
        let encodeSeconds = Date().timeIntervalSince(encodeStarted)
        let fortyImageIO = GifEncoder.encodeImageIO(forty)
        log(String(format: "(j) 40 frames %dx%d: custom %.0f ms, %d bytes; ImageIO %d bytes",
                   forty.first?.image.width ?? 0, forty.first?.image.height ?? 0,
                   encodeSeconds * 1000, fortyGIF?.count ?? -1, fortyImageIO?.count ?? -1))
        check(forty.count == 40 && Self.decodeGIF(fortyGIF ?? Data()).frames.count > 1,
              "(j) 40-frame GIF does not decode")
        check(encodeSeconds < 2, "(j) 40-frame encode took \(encodeSeconds)s")

        // (d) Crop: proportions, and the highlight where the maths says.
        let crop = CGRect(x: 0.15, y: 0.30, width: 0.40, height: 0.25)
        guide.setCrop(crop, at: 1)
        let cropSpec = plain.renderSpec(number: 2)
        let cropped = MediaPreparer.still(cropSpec, maxEdge: nil)
        write(cropped, "still-cropped.png")
        if let cropped {
            let w = CGFloat(cropped.width), h = CGFloat(cropped.height)
            let t = CGRect(x: (target.minX - crop.minX) / crop.width,
                           y: (target.minY - crop.minY) / crop.height,
                           width: target.width / crop.width, height: target.height / crop.height)
            // The box is stroked 1.5 units outside the target; a unit is the
            // visible area's longest edge / 450.
            let unit = max(w, h) / 450
            let edge = CGPoint(x: (t.minX * w - 1.5 * unit) / w, y: t.midY)
            let onEdge = Img.sample(cropped, at: edge)
            let inside = Img.sample(cropped, at: CGPoint(x: t.midX, y: t.midY))
            log("(d) crop \(cropped.width)x\(cropped.height) (expect 640x250); box edge "
                + "\(Self.describe(onEdge)), button \(Self.describe(inside))")
            check(abs(w - 640) <= 2 && abs(h - 250) <= 2, "(d) crop size \(w)x\(h)")
            check(onEdge.map { $0.r > 180 && $0.g < 120 } ?? false, "(d) highlight not on the box edge")
            check(inside.map { $0.r > 200 && $0.g > 200 && $0.b > 200 } ?? false,
                  "(d) button interior not white")
        } else {
            check(false, "(d) cropped still nil")
        }
        let small = MediaPreparer.still(cropSpec, maxEdge: 320)
        check(small.map { max($0.width, $0.height) == 320 && abs($0.height - 125) <= 1 } ?? false,
              "(d) maxEdge on a crop: \(small.map { "\($0.width)x\($0.height)" } ?? "nil")")
        // A crop that starts at the box's corner: the badge must clamp inside.
        var clampSpec = cropSpec
        clampSpec.crop = CGRect(x: 0.22, y: 0.38, width: 0.30, height: 0.25)
        let clamped = MediaPreparer.still(clampSpec, maxEdge: nil)
        write(clamped, "still-badge-clamped.png")
        // Clamped, the badge's disc spans about 1…13 px from each edge of the
        // 480 × 250 crop; 3 px in, at mid-height, is red beside the numeral.
        check(clamped.flatMap { Img.sample($0, at: CGPoint(x: 3.0 / 480, y: 6.9 / 250)) }
                .map { $0.r > 180 && $0.g < 120 } ?? false,
              "(d) badge not clamped into the crop's corner")

        // (e) Spotlight: dim outside, untouched inside; magnify adds an inset.
        var spot = plain.renderSpec(number: 2)
        spot.crop = nil
        let area = CGRect(x: 0.15, y: 0.30, width: 0.30, height: 0.25)
        let undimmed = FrameRenderer.still(spot)
        spot.spotlight = Spotlight(rect: area, mode: .dim)
        let dimmed = FrameRenderer.still(spot)
        write(dimmed, "still-dim.png")
        let outside = CGPoint(x: 0.80, y: 0.15), inside = CGPoint(x: 0.17, y: 0.52)
        if let undimmed, let dimmed,
           let o0 = Img.sample(undimmed, at: outside), let o1 = Img.sample(dimmed, at: outside),
           let i0 = Img.sample(undimmed, at: inside), let i1 = Img.sample(dimmed, at: inside) {
            log("(e) dim: outside \(Self.describe(o0)) -> \(Self.describe(o1)), "
                + "inside \(Self.describe(i0)) -> \(Self.describe(i1))")
            check(Self.luma(o1) < Self.luma(o0) * 0.6, "(e) outside not darkened")
            check(Self.near(i0, i1, 2), "(e) inside changed")
        } else {
            check(false, "(e) dim renders nil")
        }
        spot.spotlight = Spotlight(rect: area, mode: .magnify)
        let magnified = FrameRenderer.still(spot)
        write(magnified, "still-magnify.png")
        let farCorner = CGRect(x: 0.5, y: 0.5, width: 0.48, height: 0.48)
        let changed = Self.changedFraction(magnified, dimmed, in: farCorner)
        let source = Self.changedFraction(magnified, dimmed, in: area.insetBy(dx: 0.01, dy: 0.01))
        log(String(format: "(e) magnify: %.0f%% of the far corner changed, %.1f%% of the source",
                   changed * 100, source * 100))
        check(changed > 0.3, "(e) no magnifier in the far corner")
        check(source < 0.01, "(e) magnifier covers the spotlit area")
        spot.spotlight?.inset = CGPoint(x: 0.25, y: 0.80)
        let placed = FrameRenderer.still(spot)
        write(placed, "still-magnify-inset.png")
        let atInset = Self.changedFraction(placed, dimmed,
                                           in: CGRect(x: 0.2, y: 0.75, width: 0.1, height: 0.1))
        let leftAlone = Self.changedFraction(placed, dimmed, in: farCorner)
        log(String(format: "(e) inset at (0.25, 0.80): %.0f%% changed there, %.0f%% in the far corner",
                   atInset * 100, leftAlone * 100))
        check(atInset > 0.5 && leftAlone < 0.05, "(e) inset position not honoured")
        // Magnify on a GIF frame, cropped.
        var gifMagnify = spec
        gifMagnify.crop = CGRect(x: 0.05, y: 0.25, width: 0.70, height: 0.70)
        gifMagnify.spotlight = Spotlight(rect: CGRect(x: 0.18, y: 0.35, width: 0.24, height: 0.13),
                                         mode: .magnify)
        let gifFrame = FrameRenderer.frame(gifMagnify, at: 1.6, maxEdge: 1200)
        gifMagnify.spotlight?.mode = .dim
        let gifFrameDim = FrameRenderer.frame(gifMagnify, at: 1.6, maxEdge: 1200)
        write(gifFrame, "frame-magnify-cropped.png")
        let gifChanged = Self.changedFraction(gifFrame, gifFrameDim,
                                              in: CGRect(x: 0, y: 0, width: 1, height: 1))
        log(String(format: "(e) magnify on a cropped GIF frame %@: %.0f%% of pixels changed",
                   gifFrame.map { "\($0.width)x\($0.height)" } ?? "nil", gifChanged * 100))
        check(gifChanged > 0.05, "(e) GIF frame magnifier missing")

        // (f) Off-main rendering matches the main thread, byte for byte —
        // with a text label and a badge in it, the parts that used to need
        // NSGraphicsContext.
        guide.addMarkup(Markup(kind: .text, points: [CGPoint(x: 0.55, y: 0.12)], color: .red,
                               width: 0.004, text: "Rendered off the main thread 123"), at: 1)
        var offMain = plain.renderSpec(number: 2)
        offMain.spotlight = Spotlight(rect: area, mode: .magnify)
        let gifSpec = gifStep.renderSpec(number: 1)
        let mainStill = FrameRenderer.still(offMain).map(Self.rgba)
        let mainFrame = FrameRenderer.frame(gifSpec, at: 1.6, maxEdge: 900).map(Self.rgba)
        let mainGIF = MediaPreparer.gif(gifSpec, preset: .preview)
        let box = ResultBox<([UInt8]?, [UInt8]?, Data?)>()
        let finished = DispatchSemaphore(value: 0)
        let offMainSpec = offMain
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = (FrameRenderer.still(offMainSpec).map(Self.rgba),
                         FrameRenderer.frame(gifSpec, at: 1.6, maxEdge: 900).map(Self.rgba),
                         MediaPreparer.gif(gifSpec, preset: .preview))
            finished.signal()
        }
        finished.wait()
        let background = box.value
        log("(f) background vs main: still \(background?.0 == mainStill && mainStill != nil), "
            + "frame \(background?.1 == mainFrame && mainFrame != nil), "
            + "gif \(background?.2 == mainGIF && mainGIF != nil) (\(mainGIF?.count ?? -1) bytes)")
        check(mainStill != nil && background?.0 == mainStill, "(f) still differs off-main")
        check(mainFrame != nil && background?.1 == mainFrame, "(f) frame differs off-main")
        check(mainGIF != nil && background?.2 == mainGIF, "(f) GIF differs off-main")
        write(FrameRenderer.still(offMain), "still-offmain-reference.png")

        // (i) The email budget gives up instead of overshooting.
        let email = MediaPreparer.gifReport(spec, preset: .email)
        var tiny = GifPreset.email
        tiny.maxBytes = 4000
        let starved = MediaPreparer.gifReport(spec, preset: tiny)
        log("(i) email gif \(email.data?.count ?? -1) bytes at \(Int(email.preset.maxEdge))px "
            + "\(email.preset.fps)fps; 4000-byte budget -> "
            + "\(starved.data == nil ? "nil" : "\(starved.data!.count) bytes") "
            + "after \(starved.attempts) attempts")
        check(email.data != nil && (email.data?.count ?? .max) <= 1_500_000, "(i) email gif")
        check(starved.data == nil && starved.attempts == 3, "(i) tiny budget did not return nil")

        // (g) The new fields survive guide.json, and old guides still load.
        let jCrop = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        let jSpot = Spotlight(rect: CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.1),
                              mode: .magnify, zoom: 2.5, inset: CGPoint(x: 0.8, y: 0.2))
        guide.setCrop(jCrop, at: 0)
        guide.setSpotlight(jSpot, at: 0)
        guide.setMedia(.screenshot, at: 0)
        guide.setTrim(start: 0.7, end: 2.8, at: 0)
        guide.setShowPointer(false, at: 0)
        guide.save()
        let fresh = Guide()
        if fresh.load(from: folder), let s = fresh.steps.first {
            let ok = Self.close(s.crop, jCrop) && Self.close(s.spotlight?.rect, jSpot.rect)
                && s.spotlight?.mode == .magnify && abs((s.spotlight?.zoom ?? 0) - 2.5) < 1e-9
                && Self.close(s.spotlight?.inset, jSpot.inset)
                && s.media == .screenshot && s.gif?.folder == clip.folder
                && abs((s.gif?.trimStart ?? 0) - 0.7) < 1e-9 && abs((s.gif?.trimEnd ?? 0) - 2.8) < 1e-9
                && s.gif?.showPointer == false
                && fresh.steps.count == 2 && Self.close(fresh.steps[1].crop, crop)
                && fresh.steps[1].spotlight == nil && fresh.steps[1].media == .screenshot
            log("(g) round trip: crop \(s.crop.map { "\($0)" } ?? "nil"), media \(s.media.rawValue), "
                + "trim \(s.gif?.trimStart ?? -1)…\(s.gif?.trimEnd ?? -1), ok=\(ok)")
            check(ok, "(g) fields changed across save/load")
        } else {
            check(false, "(g) reload failed")
        }
        // Through JSONSerialization, as a real guide.json from before any of
        // these keys existed would arrive.
        let legacy = "{\"image\": \"\(plain.imageURL.lastPathComponent)\", \"clickX\": 0.5, "
            + "\"clickY\": 0.5, \"app\": \"Finder\", \"verb\": \"Click\", \"note\": \"old\"}"
        let old = (try? JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any])
            .flatMap { GuideStep.from($0, folder: folder) }
        check(old != nil && old?.media == .screenshot && old?.crop == nil
              && old?.spotlight == nil && old?.gif == nil,
              "(g) an old-style step does not load as a plain screenshot")
        guide.setMedia(.gif, at: 0)
        guide.setCrop(nil, at: 0)
        guide.setSpotlight(nil, at: 0)
        guide.setShowPointer(true, at: 0)

        // (h) Make Permanent reaches every footage frame.
        if let data = gifStep.clipData, let clipFolder = gifStep.clipFolderURL {
            let urls = data.frames.map { clipFolder.appendingPathComponent($0.file) }
            let before = urls.first.flatMap(Img.readPNG).flatMap { Img.sample($0, at: coverCentre) }
            let flattened = guide.flattenRedactions()
            let after = urls.map { Img.readPNG($0).flatMap { Img.sample($0, at: coverCentre) } }
            let baked = after.filter { $0.map { Self.near($0, blue, 20) } ?? false }.count
            let still = Img.readPNG(gifStep.imageURL).flatMap { Img.sample($0, at: coverCentre) }
            log("(h) flattened \(flattened) step(s); frame-0001 \(Self.describe(before)) -> "
                + "\(Self.describe(after.first ?? nil)); cover baked into \(baked)/\(urls.count) frames")
            check(before.map { !Self.near($0, blue, 20) } ?? false, "(h) cover already in the file")
            check(flattened >= 1 && baked == urls.count, "(h) frames not all flattened")
            check(still.map { Self.near($0, blue, 8) } ?? false, "(h) still not flattened")
        } else {
            check(false, "(h) no clip data")
        }

        done()
    }

    // MARK: Helpers

    /// A colour as it comes out of the renderers' DeviceRGB bitmaps.
    nonisolated private static func renderedColor(_ color: CGColor) -> (r: Int, g: Int, b: Int) {
        guard let ctx = Img.bitmap(width: 4, height: 4) else { return (0, 0, 0) }
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage().flatMap { Img.sample($0, at: CGPoint(x: 0.5, y: 0.5)) } ?? (0, 0, 0)
    }

    nonisolated private static func fontName(_ weight: CGFloat) -> String {
        CTFontCopyPostScriptName(Annotator.TextLine.systemFont(size: 20, weight: weight)) as String
    }

    nonisolated private static func near(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int),
                             _ tolerance: Int) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    nonisolated private static func luma(_ c: (r: Int, g: Int, b: Int)) -> Double {
        0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)
    }

    nonisolated private static func describe(_ c: (r: Int, g: Int, b: Int)?) -> String {
        c.map { "rgb(\($0.r),\($0.g),\($0.b))" } ?? "nil"
    }

    nonisolated private static func close(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
            && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    nonisolated private static func close(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9
    }

    /// Every frame of a GIF as ImageIO composites it, with its unclamped delay.
    nonisolated private static func decodeGIF(_ data: Data) -> (frames: [CGImage], delays: [Double]) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return ([], []) }
        var frames: [CGImage] = [], delays: [Double] = []
        for i in 0..<CGImageSourceGetCount(src) {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
            frames.append(image)
            delays.append(delay)
        }
        return (frames, delays)
    }

    /// RGBA8 sRGB pixels at the image's own size — for byte comparisons.
    nonisolated private static func rgba(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer
    }

    /// Mean absolute channel difference, and the fraction of pixels off by
    /// more than 48 in some channel — quantisation stays well under that,
    /// a broken delta frame does not.
    nonisolated private static func difference(_ a: CGImage, _ b: CGImage) -> (mean: Double, outliers: Double) {
        guard a.width == b.width, a.height == b.height else { return (255, 1) }
        let pa = rgba(a), pb = rgba(b)
        var sum = 0, outliers = 0
        var i = 0
        while i < pa.count {
            var worst = 0
            for c in 0..<3 {
                let d = abs(Int(pa[i + c]) - Int(pb[i + c]))
                sum += d
                worst = max(worst, d)
            }
            if worst > 48 { outliers += 1 }
            i += 4
        }
        let pixels = Double(pa.count / 4)
        return (Double(sum) / (pixels * 3), Double(outliers) / pixels)
    }

    /// Fraction of a 40×40 sample grid over `region` (0…1, top-left) where
    /// the two images differ by more than 8 in some channel.
    nonisolated private static func changedFraction(_ a: CGImage?, _ b: CGImage?, in region: CGRect) -> Double {
        guard let a, let b, a.width == b.width, a.height == b.height else { return -1 }
        let pa = rgba(a), pb = rgba(b)
        var changed = 0, total = 0
        for gy in 0..<40 {
            for gx in 0..<40 {
                let x = Int((region.minX + region.width * (CGFloat(gx) + 0.5) / 40) * CGFloat(a.width))
                let y = Int((region.minY + region.height * (CGFloat(gy) + 0.5) / 40) * CGFloat(a.height))
                guard x >= 0, y >= 0, x < a.width, y < a.height else { continue }
                let i = (y * a.width + x) * 4
                total += 1
                if (0..<3).contains(where: { abs(Int(pa[i + $0]) - Int(pb[i + $0])) > 8 }) { changed += 1 }
            }
        }
        return total > 0 ? Double(changed) / Double(total) : 0
    }
}
