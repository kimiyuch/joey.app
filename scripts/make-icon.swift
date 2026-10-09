// Renders the Joey app icon into an .iconset: a joey sitting in a blue folder
// with a download arrow, on a eucalyptus-green squircle.
// Usage: swift make-icon.swift <out.iconset>
import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let fur = color(0x9BA4AD), furDark = color(0x7D8791), fluff = color(0xEEF1F3), nose = color(0x2A2E33)

func oval(_ c: NSPoint, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
}

func fill(_ path: NSBezierPath, _ c: NSColor) {
    c.setFill()
    path.fill()
}

func withShadow(_ alpha: CGFloat, offset: CGFloat, blur: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha)
    shadow.shadowOffset = NSSize(width: 0, height: offset)
    shadow.shadowBlurRadius = blur
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Koala head centered at c; s is roughly the head radius.
func koalaHead(_ c: NSPoint, _ s: CGFloat) {
    for side: CGFloat in [-1, 1] {
        let ear = NSPoint(x: c.x + side * 0.78 * s, y: c.y + 0.5 * s)
        fill(oval(ear, 0.46 * s, 0.44 * s), fur)
        fill(oval(NSPoint(x: ear.x + side * 0.04 * s, y: ear.y - 0.02 * s), 0.3 * s, 0.28 * s), fluff)
    }
    fill(oval(c, 0.86 * s, 0.76 * s), fur)
    fill(oval(NSPoint(x: c.x, y: c.y - 0.22 * s), 0.5 * s, 0.4 * s), color(0xA9B1B9))
    for side: CGFloat in [-1, 1] {
        let eye = NSPoint(x: c.x + side * 0.38 * s, y: c.y + 0.14 * s)
        fill(oval(eye, 0.075 * s, 0.085 * s), nose)
        fill(oval(NSPoint(x: eye.x + 0.025 * s, y: eye.y + 0.03 * s), 0.025 * s, 0.025 * s), .white)
    }
    let n = NSPoint(x: c.x, y: c.y - 0.08 * s)
    fill(NSBezierPath(roundedRect: NSRect(x: n.x - 0.2 * s, y: n.y - 0.3 * s, width: 0.4 * s, height: 0.5 * s),
                      xRadius: 0.2 * s, yRadius: 0.2 * s), nose)
}

func downArrow(center c: NSPoint, size s: CGFloat, width: CGFloat) {
    NSColor.white.setStroke()
    let a = NSBezierPath()
    a.lineWidth = width
    a.lineCapStyle = .round
    a.lineJoinStyle = .round
    a.move(to: NSPoint(x: c.x, y: c.y + s / 2))
    a.line(to: NSPoint(x: c.x, y: c.y - s / 2))
    a.move(to: NSPoint(x: c.x - s * 0.36, y: c.y - s * 0.14))
    a.line(to: NSPoint(x: c.x, y: c.y - s / 2))
    a.line(to: NSPoint(x: c.x + s * 0.36, y: c.y - s * 0.14))
    a.stroke()
}

/// Draws the icon in a 1024×1024 coordinate space (origin bottom-left).
func drawIcon() {
    // macOS icon grid: 824pt body centered in 1024, ~185pt corner radius.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    withShadow(0.3, offset: -10, blur: 24) { fill(squircle, color(0x3F7D63)) }

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [color(0x8CC7A8), color(0x3F7D63)])!.draw(in: body, angle: -90)
    NSGradient(colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)

    // Folder back panel with its tab (mostly hidden behind the joey).
    let backPanel = NSBezierPath(roundedRect: NSRect(x: 196, y: 170, width: 632, height: 380), xRadius: 44, yRadius: 44)
    backPanel.append(NSBezierPath(roundedRect: NSRect(x: 196, y: 480, width: 250, height: 110), xRadius: 40, yRadius: 40))
    fill(backPanel, color(0x4E9FE0))

    koalaHead(NSPoint(x: 512, y: 600), 215)

    // Folder front panel.
    let frontRect = NSRect(x: 196, y: 170, width: 632, height: 300)
    let frontPanel = NSBezierPath(roundedRect: frontRect, xRadius: 44, yRadius: 44)
    withShadow(0.22, offset: 10, blur: 22) { fill(frontPanel, color(0x8FD0FF)) }
    NSGraphicsContext.saveGraphicsState()
    frontPanel.addClip()
    NSGradient(colors: [color(0x8FD0FF), color(0x62B4F2)])!.draw(in: frontRect, angle: -90)
    fill(NSBezierPath(rect: NSRect(x: 196, y: 456, width: 632, height: 14)), color(0xFFFFFF, 0.35))
    NSGraphicsContext.restoreGraphicsState()

    // Paws gripping the front edge.
    for x: CGFloat in [400, 624] {
        fill(oval(NSPoint(x: x, y: 470), 50, 38), fur)
        fill(oval(NSPoint(x: x, y: 462), 38, 24), furDark)
    }
    downArrow(center: NSPoint(x: 512, y: 300), size: 170, width: 44)
    NSGraphicsContext.restoreGraphicsState()
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
