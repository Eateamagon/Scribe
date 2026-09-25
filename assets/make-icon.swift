// Draws Scribe's app icon at 1024×1024 and writes assets/icon-1024.png.
// build.sh turns that single PNG into Scribe.icns with every size macOS wants.
//
//   swift assets/make-icon.swift mark     -> annotated-screenshot mark (default)
//   swift assets/make-icon.swift badger   -> the school logo on a purple tile
//
// Kept as a script rather than a checked-in binary so the icon can be changed
// by editing numbers instead of opening a design tool.

import Cocoa
import ImageIO
import UniformTypeIdentifiers

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mark"
let side: CGFloat = 1024

let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                              | CGBitmapInfo.byteOrder32Little.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

let accent = CGColor(red: 0.94, green: 0.16, blue: 0.35, alpha: 1)   // Scribe red
let purple = CGColor(red: 0.29, green: 0.12, blue: 0.53, alpha: 1)   // KCMS #4B1F87
let deepPurple = CGColor(red: 0.15, green: 0.05, blue: 0.28, alpha: 1)

/// macOS app icons are a rounded square inset from the full canvas, not edge to
/// edge — the system expects that margin and lays icons out assuming it.
let inset: CGFloat = side * 0.085
let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let radius = tile.width * 0.225
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius,
                      transform: nil)

func fillTile(_ top: CGColor, _ bottom: CGColor) {
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [top, bottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: tile.minX, y: tile.maxY),
                               end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    }
    ctx.restoreGState()
}

func drawBadge(_ number: String, centre: CGPoint, diameter: CGFloat) {
    let circle = CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2,
                        width: diameter, height: diameter)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: circle.insetBy(dx: -diameter * 0.07, dy: -diameter * 0.07))
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: circle)
    let text = NSAttributedString(string: number, attributes: [
        .font: NSFont.systemFont(ofSize: diameter * 0.62, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    let size = text.size()
    text.draw(at: CGPoint(x: circle.midX - size.width / 2,
                          y: circle.midY - size.height / 2))
}

/// Makes near-white pixels transparent.
///
/// The supplied artwork is drawn on a solid white background rather than a
/// transparent one — invisible on every other surface, because a web page, an
/// email and a PDF page are all white, and a glaring white rectangle the moment
/// it lands on a coloured tile.
func knockOutWhite(_ image: CGImage) -> CGImage? {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let scratch = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    scratch.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in stride(from: 0, to: pixels.count, by: 4) {
        if pixels[i] > 242, pixels[i + 1] > 242, pixels[i + 2] > 242 {
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
        }
    }
    return scratch.makeImage()
}

switch mode {
case "badger":
    // A light tile, not a purple one. The artwork is dark purple and black line
    // work with white fills, drawn for a white page: on purple the whites
    // vanish and the linework disappears into the background. Knocking the
    // white background out does not save it — the badger's own face and jersey
    // highlights are the same white.
    fillTile(CGColor(red: 0.99, green: 0.985, blue: 1, alpha: 1),
             CGColor(red: 0.93, green: 0.91, blue: 0.96, alpha: 1))
    ctx.setStrokeColor(purple)
    ctx.setLineWidth(side * 0.018)
    ctx.addPath(tilePath)
    ctx.strokePath()

    let logoURL = URL(fileURLWithPath: "assets/kcms-logo.png")
    if let src = CGImageSourceCreateWithURL(logoURL as CFURL, nil),
       let raw = CGImageSourceCreateImageAtIndex(src, 0, nil),
       let logo = knockOutWhite(raw) {
        let pad = tile.width * 0.13
        let box = tile.insetBy(dx: pad, dy: pad)
        let scale = min(box.width / CGFloat(logo.width), box.height / CGFloat(logo.height))
        let w = CGFloat(logo.width) * scale, h = CGFloat(logo.height) * scale
        ctx.draw(logo, in: CGRect(x: tile.midX - w / 2, y: tile.midY - h / 2,
                                  width: w, height: h))
    }

default:
    // A screenshot card with a highlight box and a step number on it — the
    // thing the app actually produces, rather than a generic pencil.
    fillTile(CGColor(red: 0.16, green: 0.18, blue: 0.23, alpha: 1),
             CGColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1))

    let card = CGRect(x: tile.minX + tile.width * 0.13,
                      y: tile.minY + tile.height * 0.20,
                      width: tile.width * 0.74, height: tile.height * 0.58)
    let cardRadius = card.width * 0.055

    // A second card behind, offset — reads as "a series of steps".
    let behind = card.offsetBy(dx: 0, dy: card.height * 0.19).insetBy(dx: card.width * 0.06, dy: 0)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
    ctx.addPath(CGPath(roundedRect: behind, cornerWidth: cardRadius, cornerHeight: cardRadius,
                       transform: nil))
    ctx.fillPath()

    ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1))
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: cardRadius, cornerHeight: cardRadius,
                       transform: nil))
    ctx.fillPath()

    // Window chrome bar across the top of the front card.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: cardRadius, cornerHeight: cardRadius,
                       transform: nil))
    ctx.clip()
    ctx.setFillColor(CGColor(red: 0.87, green: 0.88, blue: 0.90, alpha: 1))
    ctx.fill(CGRect(x: card.minX, y: card.maxY - card.height * 0.13,
                    width: card.width, height: card.height * 0.13))
    ctx.restoreGState()

    // The highlight box: the app's signature mark.
    let target = CGRect(x: card.minX + card.width * 0.13,
                        y: card.minY + card.height * 0.30,
                        width: card.width * 0.46, height: card.height * 0.24)
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(side * 0.020)
    ctx.addPath(CGPath(roundedRect: target, cornerWidth: target.height * 0.28,
                       cornerHeight: target.height * 0.28, transform: nil))
    ctx.strokePath()

    drawBadge("1", centre: CGPoint(x: target.minX, y: target.maxY), diameter: side * 0.155)
}

let out = URL(fileURLWithPath: "assets/icon-1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path) (\(mode))")
