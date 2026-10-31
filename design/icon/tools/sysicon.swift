// macOS（NSWorkspace / Icon Services）が実際に描くアプリアイコンを PNG に書き出す。窓は出さない。
// Finder や Dock と同じ経路で描くので、macOS 26 で灰色の台座に入れられていないか、どの大きさでどう見えるかを確かめられる。
//
// 使い方: swift sysicon.swift <アプリのパス> <出力の接頭辞> <px> [px ...]
//   → <接頭辞>-<px>.png を、背景が透明な px × px の画像として書き出す
import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else {
  FileHandle.standardError.write("使い方: swift sysicon.swift <app> <out-prefix> <px> [px ...]\n".data(using: .utf8)!)
  exit(2)
}
let app = args[1], prefix = args[2]
guard FileManager.default.fileExists(atPath: app) else {
  FileHandle.standardError.write("見つかりません: \(app)\n".data(using: .utf8)!)
  exit(1)
}
let icon = NSWorkspace.shared.icon(forFile: app)

for px in args.dropFirst(3).compactMap({ Int($0) }) {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: px, height: px)  // 1 pt = 1 px（@1x）で描く
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
  NSGraphicsContext.restoreGraphicsState()
  let out = "\(prefix)-\(px).png"
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
  print(out)
}
