import AppKit
// Snag icon: squircle (824 on 1024), three-stop gradient, top light, one bold
// white symbol, a small round badge. usage: make_icon <variant a|b|c> <out.png>
let variant = CommandLine.arguments[1], out = CommandLine.arguments[2]
let S: CGFloat = 1024, box: CGFloat = 824
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: (S - box) / 2, y: (S - box) / 2 - 8, width: box, height: box)
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath(); let n = 5.0, a = r.width / 2, b = r.height / 2
    for i in 0...360 { let t = Double(i) * .pi / 180
        let x = a * CGFloat(copysign(pow(abs(cos(t)), 2 / n), cos(t))), y = b * CGFloat(copysign(pow(abs(sin(t)), 2 / n), sin(t)))
        let pt = CGPoint(x: r.midX + x, y: r.midY + y); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }
    p.closeSubpath(); return p }
let colors: [NSColor] = switch variant {
    case "b": [NSColor(red: 0.20, green: 0.45, blue: 1.0, alpha: 1), NSColor(red: 0.45, green: 0.30, blue: 0.98, alpha: 1), NSColor(red: 0.85, green: 0.25, blue: 0.75, alpha: 1)]
    case "c": [NSColor(red: 0.12, green: 0.13, blue: 0.18, alpha: 1), NSColor(red: 0.20, green: 0.21, blue: 0.28, alpha: 1), NSColor(red: 0.30, green: 0.31, blue: 0.40, alpha: 1)]
    default: [NSColor(red: 1.0, green: 0.36, blue: 0.30, alpha: 1), NSColor(red: 0.96, green: 0.16, blue: 0.33, alpha: 1), NSColor(red: 0.74, green: 0.10, blue: 0.42, alpha: 1)] }
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.32).cgColor)
ctx.addPath(squircle(rect)); ctx.setFillColor(colors[1].cgColor); ctx.fillPath(); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(squircle(rect)); ctx.clip()
let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let shine = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(squircle(rect.insetBy(dx: 1.5, dy: 1.5))); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(3); ctx.strokePath(); ctx.restoreGState()
func symbol(_ name: String, _ pt: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight).applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)! }
// Main mark: a play frame with a down arrow ("take it home").
let main = symbol("arrow.down", 400, .black, .white)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
let ms = main.size
main.draw(in: CGRect(x: rect.midX - ms.width / 2, y: rect.midY - ms.height / 2 + 34, width: ms.width, height: ms.height))
// Tray line under the arrow.
let tray = NSBezierPath(roundedRect: CGRect(x: rect.midX - 190, y: rect.midY - 236, width: 380, height: 52), xRadius: 26, yRadius: 26)
NSColor.white.setFill(); tray.fill()
ctx.restoreGState()
// Badge: play triangle in a white circle, bottom right.
let bc = CGPoint(x: rect.maxX - 170, y: rect.minY + 190), br: CGFloat = 118
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: br * 2, height: br * 2)); ctx.restoreGState()
let play = symbol("play.fill", 112, .bold, colors[1])
play.draw(in: CGRect(x: bc.x - play.size.width / 2 + 8, y: bc.y - play.size.height / 2, width: play.size.width, height: play.size.height))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
