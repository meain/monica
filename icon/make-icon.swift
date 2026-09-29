// Renders Monica's app icon: three list rows on a soft lavender-gray tile,
// each led by a status dot (green working, amber waiting, gray idle) — the
// popover's agent list in miniature.
//
// Regenerate with `make icon` (writes icon/AppIcon.icns, which build-app.sh
// copies into the bundle).
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
    blue: CGFloat(hex & 0xff) / 255, alpha: alpha
  ).cgColor
}

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
  ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
  ctx.addPath(tilePath)
  ctx.setFillColor(rgb(0xdcdae6))
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(tilePath)
  ctx.clip()
  let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0xf4f3f8), rgb(0xdcdae6)] as CFArray, locations: nil)!
  ctx.drawLinearGradient(
    gradient, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY),
    options: [])
  ctx.restoreGState()

  // Hairline edge so the light tile doesn't dissolve into light backgrounds.
  ctx.addPath(
    CGPath(
      roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183,
      transform: nil))
  ctx.setStrokeColor(rgb(0x000000, 0.06))
  ctx.setLineWidth(4)
  ctx.strokePath()

  // Rows: status dot + a text bar. The first (working) row reads strongest.
  let rows: [(y: CGFloat, dot: CGColor, barWidth: CGFloat, barAlpha: CGFloat)] = [
    (642, rgb(0x34d27a), 380, 0.75),
    (512, rgb(0xf5a524), 300, 0.35),
    (382, rgb(0x9a98a8), 380, 0.35),
  ]
  for row in rows {
    ctx.setFillColor(row.dot)
    ctx.fillEllipse(in: CGRect(x: 290 - 34, y: row.y - 34, width: 68, height: 68))
    ctx.addPath(
      CGPath(
        roundedRect: CGRect(x: 360, y: row.y - 22, width: row.barWidth, height: 44),
        cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(rgb(0x3b3a48, row.barAlpha))
    ctx.fillPath()
  }

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
