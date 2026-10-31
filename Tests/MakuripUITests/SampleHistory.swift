import AppKit
import Foundation
import MakuripCore

@testable import MakuripUI

/// 本体の代わり（メモリの中の履歴）。貼り付け・閉じる・ピン留め・削除の呼び出しを記録する。
/// 中身はすべて自作の架空データ（試作 `makurip-design/ui/shared/data.js` と同じ文面。秘密の 2 件は #5 の範囲なので除く）
@MainActor
final class FakeHistory: HistoryActions {
    var items: [ClipItem]
    var payloads: [UUID: [(itemIndex: Int, type: String, data: Data)]]
    private(set) var pasted: [(UUID, PasteMode)] = []
    private(set) var closedCount = 0
    private(set) var dataReads = 0
    /// 定型文（一覧の順）と、貼った定型文・定型文の窓への頼み
    var snippetList: [Snippet] = []
    var dateFormat = SnippetDateFormat.slash
    private(set) var pastedSnippets: [(UUID, PasteMode)] = []
    private(set) var editRequests: [SnippetEditRequest] = []

    init(items: [ClipItem] = [], payloads: [UUID: [(itemIndex: Int, type: String, data: Data)]] = [:]) {
        self.items = items
        self.payloads = payloads
    }

    func historyItems(limit: Int) -> [ClipItem] { Array(items.prefix(limit)) }
    func paste(itemID: UUID) { pasted.append((itemID, .normal)) }
    func paste(itemID: UUID, mode: PasteMode) { pasted.append((itemID, mode)) }
    func historyDidClose() { closedCount += 1 }

    func setPinned(_ pinned: Bool, itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].isPinned = pinned
    }

    func delete(itemID: UUID) {
        items.removeAll { $0.id == itemID }
    }

    func representationInfos(itemID: UUID) -> [RepresentationInfo] {
        (payloads[itemID] ?? []).map {
            RepresentationInfo(itemIndex: $0.itemIndex, type: $0.type, byteCount: $0.data.count, storedInFile: false)
        }
    }

    func representationData(itemID: UUID, itemIndex: Int, type: String) -> Data? {
        dataReads += 1
        return payloads[itemID]?.first { $0.itemIndex == itemIndex && $0.type == type }?.data
    }

    func snippets() -> [Snippet] { snippetList }
    func pasteSnippet(id: UUID, mode: PasteMode) { pastedSnippets.append((id, mode)) }
    func openSnippetEditor(_ request: SnippetEditRequest) { editRequests.append(request) }
    func snippetDateFormat() -> SnippetDateFormat { dateFormat }
}

/// 試作と同じ架空の履歴（2026-10-31 15:30 を「現在」とする）
enum SampleHistory {
    /// 試作の「現在」
    static let now: Date = {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute) = (2026, 10, 31, 15, 30)
        return Calendar.current.date(from: components)!
    }()

    struct App {
        let id: String
        let name: String
        let top: UInt32
        let bottom: UInt32
        let symbol: String
    }

    /// 試作の APPS と同じ色の札（実在のアプリのアイコンは使わない）
    static let apps: [String: App] = [
        "claude": App(id: "com.example.claude", name: "Claude", top: 0xE3906B, bottom: 0xC4603B, symbol: "sparkle"),
        "xcode": App(id: "com.example.xcode", name: "Xcode", top: 0x55AAFF, bottom: 0x1D6BE0, symbol: "hammer.fill"),
        "shot": App(
            id: "com.example.screenshot", name: "スクリーンショット", top: 0x9A9AA0, bottom: 0x5C5C62, symbol: "viewfinder"),
        "safari": App(id: "com.example.safari", name: "Safari", top: 0x5AC8FA, bottom: 0x0A6CF0, symbol: "safari"),
        "slack": App(id: "com.example.slack", name: "Slack", top: 0x8A4A9C, bottom: 0x4A154B, symbol: "number"),
        "figma": App(id: "com.example.figma", name: "Figma", top: 0x4A4A4E, bottom: 0x1C1C1E, symbol: "pencil.tip"),
        "mirror": App(
            id: "com.example.mirroring", name: "iPhone ミラーリング", top: 0xB4B4BA, bottom: 0x6E6E74, symbol: "iphone"),
        "notes": App(id: "com.example.notes", name: "メモ", top: 0xFFD95A, bottom: 0xF2B200, symbol: "list.bullet"),
        "finder": App(id: "com.example.finder", name: "Finder", top: 0x6CC6FF, bottom: 0x2785EC, symbol: "folder.fill"),
        "mail": App(id: "com.example.mail", name: "メール", top: 0x66BBFF, bottom: 0x1774F0, symbol: "envelope.fill"),
        "vscode": App(
            id: "com.example.vscode", name: "Visual Studio Code", top: 0x41AAF2, bottom: 0x0E66B8, symbol: "curlybraces"
        ),
        "terminal": App(
            id: "com.example.terminal", name: "ターミナル", top: 0x47474B, bottom: 0x141416, symbol: "chevron.right"),
        "messages": App(
            id: "com.example.messages", name: "メッセージ", top: 0x66E27F, bottom: 0x22B347, symbol: "message.fill"),
        "meter": App(
            id: "com.example.colormeter", name: "Digital Color Meter", top: 0xB693FF, bottom: 0x7547DC,
            symbol: "eyedropper"),
        "preview": App(id: "com.example.preview", name: "プレビュー", top: 0x84D6EA, bottom: 0x2797BA, symbol: "photo"),
    ]

    @MainActor static var iconTiles: [String: AppIconProvider.Tile] {
        Dictionary(
            uniqueKeysWithValues: apps.values.map {
                (
                    $0.id,
                    AppIconProvider.Tile(
                        top: PanelPalette.hex($0.top), bottom: PanelPalette.hex($0.bottom), symbol: $0.symbol)
                )
            })
    }

    enum Body {
        case text(String)
        case rich(String, heading: String)
        case code(String)
        case command(String)
        case url(String, title: String)
        case image(name: String, width: Int, height: Int)
        case files([String])
        case color(String)
    }

    struct Entry {
        let kind: ClipKind
        let minutesAgo: Double
        let app: String
        let method: CopyMethod
        var pinned = false
        var source: String?
        let body: Body
    }

    static let day: Double = 1440

    /// 試作の定型文 6 件（`data.js` の snippets と同じ文面・順）
    static let snippets: [Snippet] = [
        ("あいさつ（社外）", ";aisatsu", "いつもお世話になっております。\n{{カーソル}}\nよろしくお願いいたします。"),
        ("今日の日付", ";date", "{{日付}}"),
        (
            "PR の説明テンプレート", ";pr",
            "## 概要\n{{カーソル}}\n\n## 変更点\n- \n\n## 確認したこと\n- [ ] ビルドが通る\n- [ ] 動作を確かめた"
        ),
        ("コードブロックで囲む", ";code", "```{{言語}}\n{{クリップボード}}\n```"),
        ("AI にレビューを頼む", ";rv", "次のコードをレビューしてください。バグ、読みやすさ、境界のケースの順に指摘してください。\n\n{{クリップボード}}"),
        ("返信：了解しました", ";ok", "承知しました。対応して、終わり次第ご連絡します。"),
    ].enumerated().map { index, entry in
        Snippet(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, name: entry.0,
            abbreviation: entry.1, body: entry.2, createdAt: now, updatedAt: now)
    }

    static let entries: [Entry] = [
        Entry(
            kind: .command, minutesAgo: 2, app: "claude", method: .other, source: "https://chat.example.ai/c/7f3a2b",
            body: .command("$ git switch -c feature/history-panel")),
        Entry(
            kind: .code, minutesAgo: 5, app: "xcode", method: .keyboard,
            body: .code(
                """
                struct HistoryRow: View {
                    let item: ClipItem
                    @Binding var isSelected: Bool

                    var body: some View {
                        HStack(spacing: 10) {
                            KindBadge(kind: item.kind)
                            Text(item.title)
                                .lineLimit(1)
                            Spacer()
                            // 相対時刻は 1 分ごとに更新する
                            Text(item.copiedAt, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                """)),
        Entry(
            kind: .image, minutesAgo: 9, app: "shot", method: .keyboard,
            body: .image(name: "h03", width: 1600, height: 1000)),
        Entry(
            kind: .url, minutesAgo: 14, app: "safari", method: .keyboard, pinned: true,
            body: .url(
                "https://developer.example.com/documentation/appkit/nspasteboard", title: "NSPasteboard | 開発者ドキュメント")),
        Entry(
            kind: .text, minutesAgo: 22, app: "slack", method: .keyboard,
            body: .text("明日のレビューは 10:00 からです。履歴パネルの案を 3 つ持っていくので、使いやすさの観点で見てもらえると助かります。")),
        Entry(kind: .color, minutesAgo: 31, app: "figma", method: .other, pinned: true, body: .color("#0A84FF")),
        Entry(
            kind: .command, minutesAgo: 38, app: "claude", method: .other, source: "https://chat.example.ai/c/91d0e4",
            body: .command("$ brew install swiftlint\n$ swiftlint --fix && swiftlint")),
        Entry(
            kind: .image, minutesAgo: 46, app: "mirror", method: .keyboard,
            body: .image(name: "h09", width: 780, height: 1688)),
        Entry(
            kind: .richText, minutesAgo: 52, app: "notes", method: .keyboard,
            body: .rich(
                "リリース前のチェック\n公証が通ったら配布ページを更新する。\n・バージョン番号を上げる\n・変更点を3 行でまとめる\n・古いビルドを消す",
                heading: "リリース前のチェック")),
        Entry(
            kind: .file, minutesAgo: 65, app: "finder", method: .keyboard,
            body: .files(["企画書_v3.pdf", "画面遷移.sketch", "history-panel.mov"])),
        Entry(
            kind: .text, minutesAgo: 80, app: "mail", method: .keyboard,
            body: .text("ﾃﾞﾌﾟﾛｲ手順：ビルド → 公証 → 配布ページ更新。ﾃﾞﾌﾟﾛｲ前に変更履歴を確認すること。")),
        Entry(
            kind: .code, minutesAgo: 100, app: "vscode", method: .keyboard,
            body: .code(
                """
                export function relativeTime(date: Date, now = new Date()): string {
                  const min = Math.round((now.getTime() - date.getTime()) / 60000);
                  if (min < 1) return "たった今";
                  if (min < 60) return `${min}分前`;
                  return `${Math.floor(min / 60)}時間前`;
                }
                """)),
        Entry(
            kind: .command, minutesAgo: 120, app: "claude", method: .other, source: "https://chat.example.ai/c/0b77c1",
            body: .command(
                "$ xcodebuild -project Makurip.xcodeproj -scheme Makurip -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData CODE_SIGN_STYLE=Manual OTHER_SWIFT_FLAGS='-warnings-as-errors' clean build | xcbeautify --renderer terminal"
            )),
        Entry(
            kind: .url, minutesAgo: 150, app: "safari", method: .keyboard,
            body: .url(
                "https://git.example.com/makurip/makurip/pull/42/files?diff=split&w=1#diff-7c3f0e9a1b2d4c5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6L118",
                title: "履歴パネルのキー操作を追加 #42")),
        Entry(
            kind: .code, minutesAgo: 180, app: "claude", method: .other, source: "https://chat.example.ai/c/5aa3f2",
            body: .code(
                """
                import re

                SECRET = re.compile(r"(sk|tok)-test-[A-Za-z0-9]{16,}")

                def looks_secret(text: str) -> bool:
                    \"\"\"API キーらしい文字列かどうかを判定する\"\"\"
                    return bool(SECRET.search(text))
                """)),
        Entry(
            kind: .text, minutesAgo: 240, app: "notes", method: .keyboard,
            body: .text(
                "長い文章の例です。クリップボード履歴アプリは、コピーした瞬間の内容を種類ごとに保存し、あとから検索して呼び出せるようにする道具です。テキストだけでなく、画像やファイル、色、リンクのように形の違うものも同じ一覧で扱います。一覧では一行に収まるところまでを見せ、全体はプレビューで確かめます。"
            )),
        Entry(
            kind: .image, minutesAgo: day + 140, app: "safari", method: .other,
            source: "https://photos.example.org/panorama/18", body: .image(name: "h19", width: 2400, height: 640)),
        Entry(kind: .color, minutesAgo: day + 210, app: "meter", method: .keyboard, body: .color("#FF9F0A")),
        Entry(
            kind: .command, minutesAgo: day + 260, app: "terminal", method: .keyboard, pinned: true,
            body: .command("% npm run build && npm run preview")),
        Entry(
            kind: .text, minutesAgo: day + 300, app: "messages", method: .keyboard, body: .text("了解です、明日の 10 時でお願いします。")
        ),
        Entry(kind: .file, minutesAgo: day + 420, app: "finder", method: .keyboard, body: .files(["見積書_サンプル.pdf"])),
        Entry(
            kind: .url, minutesAgo: 3 * day + 200, app: "safari", method: .keyboard,
            body: .url("https://www.example.co.jp/news/2026/10/", title: "お知らせ一覧 — サンプル株式会社")),
        Entry(
            kind: .image, minutesAgo: 4 * day + 30, app: "preview", method: .keyboard,
            body: .image(name: "h25", width: 1024, height: 1024)),
        Entry(
            kind: .code, minutesAgo: 6 * day, app: "claude", method: .other, source: "https://chat.example.ai/c/2c1d9e",
            body: .code(
                """
                #!/bin/zsh
                # 公証の結果を待ってから配布用の zip を作る
                xcrun notarytool submit "$APP_ZIP" --keychain-profile "$PROFILE" --wait
                ditto -c -k --keepParent "build/Makurip.app" "dist/Makurip.zip"
                """)),
        Entry(
            kind: .text, minutesAgo: 9 * day, app: "notes", method: .keyboard, pinned: true,
            body: .text("〒000-0000 東京都サンプル区見本町 1-2-3 サンプルビル 4F")),
    ]

    /// フェーズ3 のエッジケース（試作に同じ状態がないもの）。言語不明・1 文字・全角混じり・とても長い 1 行・
    /// 数千行・PS1 と出力と続き行の混じったコマンド・コピー元のページ付きの文章
    static let edgeEntries: [Entry] = [
        Entry(
            kind: .code, minutesAgo: 1, app: "vscode", method: .keyboard,
            body: .code("main :: IO ()\nmain = do\n  let xs = [1, 2, 3]\n  print (sum xs) -- 合計を出す")),
        Entry(kind: .code, minutesAgo: 2, app: "xcode", method: .keyboard, body: .code("x")),
        Entry(
            kind: .code, minutesAgo: 3, app: "xcode", method: .keyboard,
            body: .code(
                """
                // 履歴の見出し（全角の識別子と絵文字を含む）
                let 見出し = "クリップボード履歴 📋"
                guard let 件数 = Int("１２") else { return }
                print("\\(見出し)：\\(件数) 件")
                """)),
        Entry(
            kind: .code, minutesAgo: 4, app: "claude", method: .other, source: "https://chat.example.ai/c/long-line",
            body: .code(
                "const config={"
                    + (0..<160).map { "item\($0):{id:\($0),label:\"項目\($0)\",enabled:true}" }.joined(separator: ",")
                    + "};export default config;")),
        Entry(
            kind: .code, minutesAgo: 5, app: "xcode", method: .keyboard,
            body: .code(longSwift(lines: 3000))),
        Entry(
            kind: .command, minutesAgo: 6, app: "terminal", method: .keyboard,
            body: .command(
                """
                sample@MacBook-Pro makurip % make check
                swift format lint --strict --recursive Sources Tests
                Build complete!
                sample@MacBook-Pro makurip % docker run --rm \\
                > -v "$PWD":/work \\
                > ubuntu ls /work
                # コメントの行はそのまま
                """)),
        Entry(
            kind: .text, minutesAgo: 7, app: "safari", method: .keyboard,
            source: "https://docs.example.com/guide/%E5%B1%A5%E6%AD%B4?token=sample",
            body: .text("コピー元のページが取れた文章の例です。")),
    ]

    /// 行数を決めた Swift のコード（速さの計測とエッジケース用）
    static func longSwift(lines: Int) -> String {
        let unit = [
            "struct Row: View {",
            "    let item: ClipItem // 履歴 1 件",
            "    @Binding var isSelected: Bool",
            "    var body: some View { Text(\"label \\(item.id)\").padding(.horizontal, 12) }",
            "}",
        ]
        return (0..<lines).map { unit[$0 % unit.count] }.joined(separator: "\n")
    }

    /// 履歴を作る。`imageDirectory` に試作の画像（h03.png など）があればそれを、なければ図形を描いた画像を使う
    @MainActor
    static func make(imageDirectory: URL? = nil, entries: [Entry] = entries) -> FakeHistory {
        var items: [ClipItem] = []
        var payloads: [UUID: [(itemIndex: Int, type: String, data: Data)]] = [:]
        for entry in entries {
            let id = UUID()
            let app = apps[entry.app]!
            var reps: [(Int, String, Data)] = []
            var preview: String?
            func text(_ value: String) -> (Int, String, Data) { (0, PasteboardTypes.utf8PlainText, Data(value.utf8)) }
            switch entry.body {
            case .text(let value), .code(let value), .command(let value), .color(let value):
                reps.append(text(value))
                // 本物のストアと同じく、一覧の平文は先頭 1000 文字（Limits.previewCharacterLimit）
                preview = String(value.prefix(Limits.default.previewCharacterLimit))
            case .rich(let value, let heading):
                reps.append(text(value))
                reps.append((0, PasteboardTypes.rtf, rtf(value, heading: heading)))
                preview = value
            case .url(let value, let title):
                reps.append(text(value))
                reps.append((0, PasteboardTypes.url, Data(value.utf8)))
                reps.append((0, "public.url-name", Data(title.utf8)))
                preview = value
            case .image(let name, let width, let height):
                let file = imageDirectory?.appendingPathComponent("\(name).png")
                let data =
                    file.flatMap { try? Data(contentsOf: $0) } ?? drawnImage(width: width / 10, height: height / 10)
                reps.append((0, PasteboardTypes.png, data))
            case .files(let names):
                for (index, name) in names.enumerated() {
                    let url = URL(fileURLWithPath: "/Users/sample/Documents/Makurip/\(name)")
                    reps.append((index, PasteboardTypes.fileURL, Data(url.absoluteString.utf8)))
                }
                preview = names.joined(separator: "\n")
            }
            let date = now.addingTimeInterval(-entry.minutesAgo * 60)
            items.append(
                ClipItem(
                    id: id, contentHash: id.uuidString, kind: entry.kind, copyMethod: entry.method,
                    source: SourceApp(bundleID: app.id, name: app.name), sourceURL: entry.source, createdAt: date,
                    lastUsedAt: date, copyCount: 1, isPinned: entry.pinned, flags: [], previewText: preview,
                    totalBytes: reps.reduce(0) { $0 + $1.2.count },
                    pasteboardItemCount: (reps.map(\.0).max() ?? 0) + 1))
            payloads[id] = reps.map { (itemIndex: $0.0, type: $0.1, data: $0.2) }
        }
        return FakeHistory(items: items, payloads: payloads)
    }

    /// 見出しを太字にした RTF
    static func rtf(_ text: String, heading: String) -> Data {
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        result.addAttributes(
            [.font: NSFont.boldSystemFont(ofSize: 17)],
            range: NSRange(location: 0, length: (heading as NSString).length))
        if let range = text.range(of: "公証") {
            result.addAttributes([.font: NSFont.boldSystemFont(ofSize: 12)], range: NSRange(range, in: text))
        }
        return
            (try? result.data(
                from: NSRange(location: 0, length: result.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
            ?? Data()
    }

    /// 描いた画像は 1 回だけ作って使い回す（テストのたびにメインスレッドで PNG を作ると、
    /// 同時に走るペーストボード監視のテストのタイマーを待たせてしまう）
    @MainActor private static var drawnCache: [String: Data] = [:]

    /// 図形を描いた小さい PNG（試作の画像が手元にないとき）
    @MainActor
    static func drawnImage(width: Int, height: Int) -> Data {
        let key = "\(width)x\(height)"
        if let cached = drawnCache[key] { return cached }
        let data = draw(width: width, height: height)
        drawnCache[key] = data
        return data
    }

    private static func draw(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(red: 0.37, green: 0.55, blue: 1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// 速さを測るための大量の履歴（文章・コマンド・コードを混ぜる）
    @MainActor
    static func bulk(count: Int) -> FakeHistory {
        let kinds: [ClipKind] = [.text, .command, .code, .url, .text, .richText]
        let items = (0..<count).map { index -> ClipItem in
            let date = now.addingTimeInterval(-Double(index) * 90)
            let body = "項目 \(index) のテスト用の文章です。コピーした内容 sample-\(index) を検索で探せるか確かめる。"
            return ClipItem(
                id: UUID(), contentHash: "\(index)", kind: kinds[index % kinds.count],
                copyMethod: index % 3 == 0 ? .other : .keyboard,
                source: SourceApp(bundleID: "com.example.app\(index % 12)", name: "アプリ\(index % 12)"), sourceURL: nil,
                createdAt: date, lastUsedAt: date, copyCount: 1, isPinned: index % 50 == 0, flags: [],
                previewText: String(repeating: body, count: 8), totalBytes: 800, pasteboardItemCount: 1)
        }
        return FakeHistory(items: items)
    }
}
