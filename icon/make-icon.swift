// Renders Monica's app icon: the menu bar status strip (▶ working,
// ◆ waiting, ○ idle — same shapes and colors as the popover rows) on the
// blue→purple gradient the Settings header uses.
//
// Regenerate with `make icon` (writes icon/AppIcon.icns, which build-app.sh
// copies into the bundle).
import AppKit

func render(size: CGFloat) -> Data {
  let px = Int(size)
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let ctx = NSGraphicsContext.current!.cgContext
  // Draw in a 1024-unit canvas regardless of output size.
  ctx.scaleBy(x: size / 1024, y: size / 1024)

  // macOS icon grid: 824pt rounded square centered in 1024, soft drop shadow.
  let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
  let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
  ctx.saveGState()
  ctx.setShadow(
    offset: CGSize(width: 0, height: -12), blur: 28,
    color: NSColor.black.withAlphaComponent(0.35).cgColor)
  ctx.addPath(tilePath)
  ctx.setFillColor(NSColor.black.cgColor)
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(tilePath)
  ctx.clip()
  let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
      NSColor(srgbRed: 0.24, green: 0.45, blue: 0.98, alpha: 1).cgColor,
      NSColor(srgbRed: 0.55, green: 0.30, blue: 0.90, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(
    gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY),
    options: [])
  // Subtle top sheen, fading out toward the middle.
  let sheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
      NSColor.white.withAlphaComponent(0.14).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(
    sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
  ctx.restoreGState()

  // The "menu bar" strip.
  let strip = CGRect(x: 170, y: 392, width: 684, height: 240)
  ctx.addPath(CGPath(roundedRect: strip, cornerWidth: 120, cornerHeight: 120, transform: nil))
  ctx.setFillColor(NSColor(srgbRed: 0.07, green: 0.08, blue: 0.13, alpha: 0.88).cgColor)
  ctx.fillPath()

  let cy = strip.midY
  let glyph: CGFloat = 132
  let centers: [CGFloat] = [strip.minX + 142, strip.midX, strip.maxX - 142]

  // ▶ working — green, with a soft glow like the popover's working dot.
  ctx.saveGState()
  let green = NSColor(srgbRed: 0.20, green: 0.84, blue: 0.40, alpha: 1).cgColor
  ctx.setShadow(offset: .zero, blur: 30, color: green)
  let x0 = centers[0]
  ctx.move(to: CGPoint(x: x0 - glyph * 0.38, y: cy + glyph / 2))
  ctx.addLine(to: CGPoint(x: x0 + glyph * 0.52, y: cy))
  ctx.addLine(to: CGPoint(x: x0 - glyph * 0.38, y: cy - glyph / 2))
  ctx.closePath()
  ctx.setFillColor(green)
  ctx.fillPath()
  ctx.restoreGState()

  // ◆ waiting — orange diamond.
  let x1 = centers[1]
  let d = glyph * 0.56
  ctx.move(to: CGPoint(x: x1, y: cy + d))
  ctx.addLine(to: CGPoint(x: x1 + d, y: cy))
  ctx.addLine(to: CGPoint(x: x1, y: cy - d))
  ctx.addLine(to: CGPoint(x: x1 - d, y: cy))
  ctx.closePath()
  ctx.setFillColor(NSColor(srgbRed: 1.0, green: 0.62, blue: 0.10, alpha: 1).cgColor)
  ctx.fillPath()

  // ○ idle — light gray ring.
  let r = glyph * 0.44
  ctx.setStrokeColor(NSColor(white: 0.78, alpha: 1).cgColor)
  ctx.setLineWidth(22)
  ctx.strokeEllipse(in: CGRect(x: centers[2] - r, y: cy - r, width: r * 2, height: r * 2))

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try render(size: CGFloat(base * scale)).write(to: outDir.appendingPathComponent(name))
  }
}
