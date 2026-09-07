import AppKit
// Renders the Vunu app icon: cream rounded square, ink 4-bar mark, lilac dot.
let sizes = [16, 32, 128, 256, 512, 1024]
let outDir = CommandLine.arguments[1]
for px in sizes {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        let inset = s * 0.05
        let r = rect.insetBy(dx: inset, dy: inset)
        let bg = NSBezierPath(roundedRect: r, xRadius: s * 0.22, yRadius: s * 0.22)
        NSColor(srgbRed: 1, green: 1, blue: 0xEB/255, alpha: 1).setFill(); bg.fill()
        NSColor(srgbRed: 0x4D/255, green: 0x4A/255, blue: 0x42/255, alpha: 0.35).setStroke(); bg.lineWidth = max(1, s * 0.01); bg.stroke()
        let heights: [CGFloat] = [0.22, 0.42, 0.62, 0.32].map { $0 * s }
        let w = s * 0.09, gap = s * 0.06
        let total = 4 * w + 3 * gap
        let x0 = (s - total) / 2
        NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1).setFill()
        for (i, h) in heights.enumerated() {
            NSBezierPath(roundedRect: NSRect(x: x0 + CGFloat(i) * (w + gap), y: (s - h) / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
        }
        NSColor(srgbRed: 0xF0/255, green: 0xD7/255, blue: 1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: s * 0.68, y: s * 0.68, width: s * 0.12, height: s * 0.12)).fill()
        return true
    }
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name: String
    switch px { case 1024: name = "icon_512x512@2x.png"; default: name = "icon_\(px)x\(px).png" }
    try? png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("icons written")
