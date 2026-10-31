// PNG を数値で点検する。窓は出さない。
//   - 寸法
//   - 不透明部分の外接矩形（端に触れていれば切れの疑い）
//   - 四隅の不透明度（アプリアイコンの平面版なら 0 = 角丸の外が透明）
//   - 不透明部分に黒以外の色が混ざっていないか（メニューバーのテンプレート画像は黒 + 透明度だけであるべき）
//
// 使い方: swift checkpng.swift <png> [png ...]
import AppKit

for path in CommandLine.arguments.dropFirst() {
  guard let data = FileManager.default.contents(atPath: path),
        let src = NSBitmapImageRep(data: data), let cg = src.cgImage else {
    print("\(path): 読めません"); continue
  }
  let w = cg.width, h = cg.height
  var buf = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
  var minX = w, minY = h, maxX = -1, maxY = -1, colored = 0, visible = 0, partial = 0
  for y in 0..<h {
    for x in 0..<w {
      let i = (y * w + x) * 4
      let a = buf[i + 3]
      if a == 0 { continue }
      visible += 1
      if a < 255 { partial += 1 }
      // 乗算済みアルファなので、黒なら RGB はすべて 0 になる
      if buf[i] > 2 || buf[i + 1] > 2 || buf[i + 2] > 2 { colored += 1 }
      minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
  }
  let corner = { (x: Int, y: Int) -> UInt8 in buf[(y * w + x) * 4 + 3] }
  let corners = [corner(0, 0), corner(w - 1, 0), corner(0, h - 1), corner(w - 1, h - 1)]
  let bbox = maxX < 0 ? "なし" : "x \(minX)…\(maxX), y \(minY)…\(maxY)"
  let touches = maxX >= 0 && (minX == 0 || minY == 0 || maxX == w - 1 || maxY == h - 1)
  print("\(path): \(w)x\(h) 不透明部分=\(bbox)\(touches ? "（端に接する）" : "") 四隅α=\(corners) " +
        "可視ピクセル=\(visible) 半透明=\(partial) 黒以外=\(colored)")
}
