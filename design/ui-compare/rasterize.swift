// 試作の画像（SVG）を元の画素数の PNG にする（比較用。shoot.sh から使う）
// 使い方: swift rasterize.swift <SVG のフォルダ> <出力フォルダ> <名前...>
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
let source = URL(fileURLWithPath: args[0])
let output = URL(fileURLWithPath: args[1])
for name in args.dropFirst(2) {
    guard let image = NSImage(contentsOf: source.appendingPathComponent("\(name).svg")) else { continue }
    let width = Int(image.size.width)
    let height = Int(image.size.height)
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
    print("\(name) \(width)x\(height)")
}
