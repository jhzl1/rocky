// Builds Rocky's app icon from the logo: a white rounded square (the macOS icon grid, 824 of 1024 points, corner
// radius 22.37%) with the logo's center crop inside it. Writes Resources/Rocky.icns and the in-app copy
// Sources/RockyUI/Resources/Icons/rocky.png.
// Usage: swift scripts/make-icon.swift [logo=Resources/AppIcon-source.jpg]
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourcePath = CommandLine.arguments.dropFirst().first ?? root.appendingPathComponent("Resources/AppIcon-source.jpg").path
guard let data = FileManager.default.contents(atPath: sourcePath),
      let source = NSBitmapImageRep(data: data)?.cgImage else {
    fatalError("cannot read \(sourcePath)")
}
// The logo sits on a wide white margin: keep a centered square of 5/7 of the image around the drawing.
let side = CGFloat(min(source.width, source.height)) * 5 / 7
let crop = CGRect(x: (CGFloat(source.width) - side) / 2, y: (CGFloat(source.height) - side) / 2, width: side, height: side)
guard let cropped = source.cropping(to: crop) else { fatalError("cannot crop the logo") }
let logo = NSImage(cgImage: cropped, size: NSSize(width: side, height: side))

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let size = CGFloat(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
    NSColor.white.setFill()
    shape.fill()
    shape.addClip()
    logo.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Rocky-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let icns = root.appendingPathComponent("Resources/Rocky.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(pixels: 256).write(to: root.appendingPathComponent("Sources/RockyUI/Resources/Icons/rocky.png"))
print(icns.path)
