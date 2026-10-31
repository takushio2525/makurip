// tako:run swift run MakuripDevTool help
//
// 検証用 CLI（.app には入れない）。テストデータを書く・型の一覧を出す・一般ペーストボードの退避と復元・
// 隔離した Makurip への遠隔操作・pid 宛てのキー送信。
//
// 安全: 中身（平文・データ）は出力しない。出すのは型名・バイト数・件数・ハッシュの先頭だけ。
// キーは必ず pid 宛て（postToPid）で送り、前面のアプリには送らない。
import AppKit
import ApplicationServices
import CryptoKit
import MakuripCore

struct DevToolError: Error, CustomStringConvertible {
    let description: String
}

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func pasteboard(named name: String?) -> NSPasteboard {
    guard let name, name != "general" else { return .general }
    return NSPasteboard(name: NSPasteboard.Name(name))
}

func readSnapshot(_ board: NSPasteboard) -> PasteboardSnapshot {
    switch PasteboardReader.read(board, maxRepresentationBytes: Int.max) {
    case .excluded:
        // 退避・復元・型の一覧では印付きの項目もそのまま扱う（データは出力しない）
        let items = (board.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(
                representations: item.types.compactMap { type in
                    item.data(forType: type).map { PasteboardRepresentation(type: type.rawValue, data: $0) }
                })
        }
        return PasteboardSnapshot(items: items)
    case .snapshot(let snapshot, _):
        return snapshot
    }
}

func digest(_ snapshot: PasteboardSnapshot) -> String {
    var hasher = SHA256()
    for item in snapshot.items {
        hasher.update(data: Data("item".utf8))
        for rep in item.representations {
            hasher.update(data: Data(rep.type.utf8))
            hasher.update(data: rep.data)
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
}

// MARK: テストデータ（すべて自作）

func token() -> String { String(UUID().uuidString.prefix(8)) }

func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    if let data = rep.bitmapData {
        // 単純なグラデーション（ランダムにすると TIFF が圧縮されず大きくなる点を large で使う）
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * rep.bytesPerRow) + x * 4
                data[offset] = UInt8((x * 255) / max(1, width - 1))
                data[offset + 1] = UInt8((y * 255) / max(1, height - 1))
                data[offset + 2] = 180
                data[offset + 3] = 255
            }
        }
    }
    return rep
}

func noisyBitmap(width: Int, height: Int) -> NSBitmapImageRep {
    let big = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    if let data = big.bitmapData {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0..<(big.bytesPerRow * height) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            data[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
    }
    return big
}

func fixture(_ name: String, fileDirectory: String?) throws -> [NSPasteboardItem] {
    func item(_ reps: [(String, Data)]) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for (type, data) in reps { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        return item
    }
    func text(_ string: String) -> (String, Data) { (PasteboardTypes.utf8PlainText, Data(string.utf8)) }

    switch name {
    case "text":
        return [item([text("Makurip E2E のテキスト \(token())")])]
    case "rtf":
        let string = NSAttributedString(
            string: "Makurip E2E のリッチテキスト \(token())",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.systemRed])
        let rtf = try string.data(
            from: NSRange(location: 0, length: string.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return [item([(PasteboardTypes.rtf, rtf), text(string.string)])]
    case "html":
        let id = token()
        return [item([(PasteboardTypes.html, Data("<b>Makurip E2E</b> \(id)".utf8)), text("Makurip E2E \(id)")])]
    case "image":
        let rep = bitmap(width: 96, height: 64 + Int.random(in: 0..<32))
        return [
            item([
                (PasteboardTypes.png, rep.representation(using: .png, properties: [:])!),
                (PasteboardTypes.tiff, rep.tiffRepresentation!),
            ])
        ]
    case "image-large":
        // 圧縮の効かない 4000x4000 の TIFF（約 64 MB > 型 1 つの上限 50 MB）と小さい PNG
        let large = noisyBitmap(width: 4000, height: 4000)
        let small = bitmap(width: 64, height: 64)
        return [
            item([
                (PasteboardTypes.tiff, large.tiffRepresentation!),
                (PasteboardTypes.png, small.representation(using: .png, properties: [:])!),
            ])
        ]
    case "image-too-large":
        // 上限を超える型しかない（保存されないはず）
        let large = noisyBitmap(width: 4000, height: 4000)
        return [item([(PasteboardTypes.tiff, large.tiffRepresentation!)])]
    case "file":
        guard let fileDirectory else { throw DevToolError(description: "file には --file-dir が要る") }
        let url = URL(fileURLWithPath: fileDirectory).appendingPathComponent("makurip-e2e-\(token()).txt")
        try Data("Makurip E2E のファイル\n".utf8).write(to: url)
        let entry = NSPasteboardItem()
        entry.setString(url.absoluteString, forType: .fileURL)
        entry.setString(url.lastPathComponent, forType: .string)
        return [entry]
    case "concealed":
        return [item([text("not-a-real-password-\(token())"), (PasteboardMarkers.concealed, Data())])]
    case "transient":
        return [item([text("transient-\(token())"), (PasteboardMarkers.transient, Data())])]
    case "autogenerated":
        return [item([text("autogenerated-\(token())"), (PasteboardMarkers.autoGenerated, Data())])]
    case "color":
        let color = NSColor(calibratedRed: CGFloat.random(in: 0...1), green: 0.5, blue: 0.2, alpha: 1)
        let archived = try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        return [item([(PasteboardTypes.color, archived)])]
    case "code":
        return [item([text("func makuripE2E_\(token())() -> Int {\n    let value = 42\n    return value\n}")])]
    case "command":
        return [item([text("$ git log --oneline -n \(Int.random(in: 1...99))")])]
    case "url":
        return [item([text("https://example.com/makurip-e2e/\(token())")])]
    case "many-types":
        var reps = [text("Makurip E2E 型の多い項目 \(token())")]
        for i in 0..<40 { reps.append(("com.takushio2525.makurip.e2e.type-\(i)", Data("value-\(i)".utf8))) }
        return [item(reps)]
    case "multi-item":
        let id = token()
        return (1...3).map { item([text("Makurip E2E 項目 \($0) / \(id)")]) }
    case "empty":
        return []
    default:
        throw DevToolError(description: "知らないテストデータ: \(name)")
    }
}

// MARK: キー（pid 宛て）

func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], unicode: [UniChar]? = nil, to pid: pid_t) {
    let source = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
        event.flags = flags
        if let unicode { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
        event.postToPid(pid)
        usleep(15_000)
    }
}

// MARK: 命令

@MainActor
func run() throws {
    guard let command = arguments.first else { throw DevToolError(description: usage) }
    arguments.removeFirst()
    switch command {
    case "pb-write":
        let board = pasteboard(named: option("--pasteboard"))
        let fileDirectory = option("--file-dir")
        guard let name = arguments.first else { throw DevToolError(description: "テストデータの名前が要る") }
        let items = try fixture(name, fileDirectory: fileDirectory)
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
        let typeCount = items.reduce(0) { $0 + $1.types.count }
        print("wrote fixture=\(name) items=\(items.count) types=\(typeCount) changeCount=\(board.changeCount)")

    case "pb-types":
        let snapshot = readSnapshot(pasteboard(named: option("--pasteboard")))
        print("items=\(snapshot.items.count) digest=\(digest(snapshot))")
        for (index, item) in snapshot.items.enumerated() {
            for rep in item.representations { print("  [\(index)] \(rep.type) \(rep.data.count)B") }
        }

    case "pb-digest":
        let snapshot = readSnapshot(pasteboard(named: option("--pasteboard")))
        print(
            "items=\(snapshot.items.count) types=\(snapshot.items.reduce(0) { $0 + $1.representations.count }) digest=\(digest(snapshot))"
        )

    case "pb-stash":
        // 一般ペーストボードの中身を名前付きペーストボードへ写す（ディスクには書かない）
        guard let name = option("--to") else { throw DevToolError(description: "--to が要る") }
        let snapshot = readSnapshot(.general)
        let target = NSPasteboard(name: NSPasteboard.Name(name))
        PasteboardWriter.write(snapshot, to: target)
        print("stashed items=\(snapshot.items.count) digest=\(digest(snapshot))")

    case "pb-unstash":
        guard let name = option("--from") else { throw DevToolError(description: "--from が要る") }
        let source = NSPasteboard(name: NSPasteboard.Name(name))
        let snapshot = readSnapshot(source)
        if snapshot.items.isEmpty {
            NSPasteboard.general.clearContents()
        } else {
            PasteboardWriter.write(snapshot, to: .general)
        }
        source.releaseGlobally()
        print("restored items=\(snapshot.items.count) digest=\(digest(readSnapshot(.general)))")

    case "pb-release":
        guard let name = arguments.first else { throw DevToolError(description: "名前が要る") }
        NSPasteboard(name: NSPasteboard.Name(name)).releaseGlobally()
        print("released")

    case "post-keys":
        guard let pidText = option("--pid"), let pid = pid_t(pidText) else {
            throw DevToolError(description: "--pid が要る")
        }
        if let text = option("--text") {
            for scalar in text.utf16 {
                postKey(0, unicode: [scalar], to: pid)
            }
        }
        if let key = option("--key") {
            switch key {
            case "return": postKey(36, unicode: [0x0D], to: pid)
            case "escape": postKey(53, unicode: [0x1B], to: pid)
            case "down": postKey(125, to: pid)
            case "up": postKey(126, to: pid)
            case "cmd-v": postKey(9, flags: .maskCommand, unicode: [0x76], to: pid)
            case "cmd-c": postKey(8, flags: .maskCommand, unicode: [0x63], to: pid)
            case "cmd-a": postKey(0, flags: .maskCommand, unicode: [0x61], to: pid)
            default: throw DevToolError(description: "知らないキー: \(key)")
            }
        }
        print("posted to pid=\(pid)")

    case "notify":
        guard let dataDir = option("--data-dir"), let name = arguments.first else {
            throw DevToolError(description: "--data-dir と命令名が要る")
        }
        let path = URL(fileURLWithPath: (dataDir as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.path
        var userInfo: [String: Any] = [:]
        if let pid = option("--pid") { userInfo["pid"] = pid }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.takushio2525.makurip.debug." + name), object: path,
            userInfo: userInfo.isEmpty ? nil : userInfo, deliverImmediately: true)
        print("notified \(name)")

    case "window-id":
        guard let pidText = option("--pid"), let pid = Int(pidText) else {
            throw DevToolError(description: "--pid が要る")
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
            .filter { ($0[kCGWindowLayer as String] as? Int ?? 0) >= 0 }
            .compactMap { info -> (Int, CGFloat)? in
                guard let id = info[kCGWindowNumber as String] as? Int,
                    let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
                else { return nil }
                return (id, (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0))
            }
            .sorted { $0.1 > $1.1 }
        guard let first = windows.first else { throw DevToolError(description: "窓が見つからない") }
        print(first.0)

    case "image-stats":
        guard let path = arguments.first, let image = NSImage(contentsOfFile: path),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw DevToolError(description: "画像を読めない") }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        var colors = Set<UInt32>()
        var luminance = 0.0
        var samples = 0
        let step = max(1, min(rep.pixelsWide, rep.pixelsHigh) / 64)
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = UInt32(color.redComponent * 255)
                let g = UInt32(color.greenComponent * 255)
                let b = UInt32(color.blueComponent * 255)
                colors.insert(r << 16 | g << 8 | b)
                luminance += 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
                samples += 1
            }
        }
        print(
            "size=\(rep.pixelsWide)x\(rep.pixelsHigh) uniqueColors=\(colors.count) meanLuminance=\(Int(luminance / Double(max(1, samples))))"
        )

    case "frontmost":
        let app = NSWorkspace.shared.frontmostApplication
        print("\(app?.bundleIdentifier ?? "nil") pid=\(app?.processIdentifier ?? 0)")

    case "ax-check":
        print("accessibilityTrusted=\(AXIsProcessTrusted())")

    case "help":
        print(usage)

    default:
        throw DevToolError(description: usage)
    }
}

let usage = """
    使い方: MakuripDevTool <命令>
      pb-write [--pasteboard NAME|general] [--file-dir DIR] <text|rtf|html|image|image-large|image-too-large|file|concealed|transient|autogenerated|color|code|command|url|many-types|multi-item|empty>
      pb-types [--pasteboard NAME|general]     型名とバイト数の一覧（中身は出さない）
      pb-digest [--pasteboard NAME|general]    中身のハッシュの先頭だけ
      pb-stash --to NAME                       一般ペーストボードを名前付きへ退避
      pb-unstash --from NAME                   退避したものを一般ペーストボードへ戻して名前付きを消す
      pb-release NAME
      post-keys --pid PID [--text S] [--key return|escape|up|down|cmd-v|cmd-c|cmd-a]   pid 宛てにキーを送る
      notify --data-dir DIR <toggleHistory|simulateCopyShortcut|setPasteTarget|writeStatus|quit> [--pid PID]
      window-id --pid PID                      その pid のいちばん大きい窓の番号（screencapture -l 用）
      image-stats PATH                         画像が真っ黒でないかの確認用
      frontmost | ax-check | help
    """

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
