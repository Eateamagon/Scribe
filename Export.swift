//
//  Scribe — export themes and exporters
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
// MARK: - Async doorways
//
// What the editor calls. A guide with GIF steps takes seconds to encode, so
// these are where that work moves off the main thread; callers show
// "Rendering GIFs…" while they wait. The synchronous functions above stay
// correct on their own (self-tests use them).
// ─────────────────────────────────────────────────────────────────────────────

extension Export {
    static func htmlAsync(_ guide: Guide) async -> String { html(guide) }
    static func emailHTMLAsync(_ guide: Guide) async -> String { emailHTML(guide) }
    /// Returns the byte count put on the clipboard.
    static func copyForEmailAsync(_ guide: Guide) async -> Int { copyForEmail(guide) }
    static func markdownAsync(_ guide: Guide, to folder: URL) async throws {
        try markdown(guide, to: folder)
    }
}
