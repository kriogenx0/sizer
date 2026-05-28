import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

func makeSizerIcon(dim: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: dim, height: dim), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let s = dim / 18
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.boldSystemFont(ofSize: 10 * s),
            .foregroundColor: NSColor.black,
        ]
        let str = "S" as NSString
        let sz  = str.size(withAttributes: attrs)
        str.draw(at: CGPoint(x: (dim - sz.width) / 2, y: (dim - sz.height) / 2),
                 withAttributes: attrs)
        func arrow(tip: CGPoint, l: CGPoint, r: CGPoint) {
            ctx.beginPath(); ctx.move(to: tip)
            ctx.addLine(to: l); ctx.addLine(to: r)
            ctx.closePath(); ctx.fillPath()
        }
        ctx.setFillColor(NSColor.black.cgColor)
        let m = dim / 2
        arrow(tip: CGPoint(x: m,         y: dim-1*s), l: CGPoint(x: m-2.5*s, y: dim-4.5*s), r: CGPoint(x: m+2.5*s, y: dim-4.5*s))
        arrow(tip: CGPoint(x: m,         y: 1*s),     l: CGPoint(x: m-2.5*s, y: 4.5*s),     r: CGPoint(x: m+2.5*s, y: 4.5*s))
        arrow(tip: CGPoint(x: 1*s,       y: m),       l: CGPoint(x: 4.5*s,   y: m-2.5*s),   r: CGPoint(x: 4.5*s,   y: m+2.5*s))
        arrow(tip: CGPoint(x: dim - 1*s, y: m),       l: CGPoint(x: dim-4.5*s, y: m-2.5*s), r: CGPoint(x: dim-4.5*s, y: m+2.5*s))
        return true
    }
}

func pngData(for image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

let iconsetPath = "Resources/Sizer.iconset"
try FileManager.default.createDirectory(atPath: iconsetPath,
                                         withIntermediateDirectories: true)

// (logicalPt, renderPx, hiDPI)
let specs: [(Int, Int, Bool)] = [
    (16,  16,   false), (16,  32,   true),
    (32,  32,   false), (32,  64,   true),
    (128, 128,  false), (128, 256,  true),
    (256, 256,  false), (256, 512,  true),
    (512, 512,  false), (512, 1024, true),
]

var ok = true
for (logical, pixels, hiDPI) in specs {
    let name = hiDPI ? "icon_\(logical)x\(logical)@2x.png"
                     : "icon_\(logical)x\(logical).png"
    guard let data = pngData(for: makeSizerIcon(dim: CGFloat(pixels))) else {
        fputs("ERROR: failed to render \(name)\n", stderr); ok = false; continue
    }
    do {
        try data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
    } catch {
        fputs("ERROR: \(error)\n", stderr); ok = false
    }
}
exit(ok ? 0 : 1)
