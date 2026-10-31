import AppKit
import Foundation
import MakuripCore
import SwiftUI
import Testing

@testable import MakuripUI

/// パネルをオフスクリーンで PNG に描き、試作のスクショと横に並べた比較画像を作る（見た目の検証用）。
///
/// 画面ロック中でも描ける（NSHostingView を枠なしの窓に載せ、`cacheDisplay` で描く。TextField や ScrollView も写る）。
/// 環境変数を付けたときだけ動く:
///
/// ```
/// MAKURIP_SNAPSHOT_DIR=<出力先> \
/// MAKURIP_SNAPSHOT_ASSETS=<試作の画像の PNG（h03.png など）> \
/// MAKURIP_PROTO_SHOTS=<試作をヘッドレス Chrome で撮った PNG（light.png など）> \
///   swift test --filter Snapshot
/// ```
///
/// 試作側はぼかしを切って単色の背景に置き、パネルを CSS の (40, 40) に固定して 2 倍で撮ったもの。
/// こちらも同じ背景色の上に、同じ位置で描く（`backdrop`）。データは試作と同じ架空の履歴（秘密の 2 件を除く）
@MainActor
@Suite("オフスクリーン描画", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"] != nil))
struct SnapshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"] ?? "/dev/null")
    let assets = ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_ASSETS"].map { URL(fileURLWithPath: $0) }
    let protoShots = ProcessInfo.processInfo.environment["MAKURIP_PROTO_SHOTS"].map { URL(fileURLWithPath: $0) }

    struct Scenario {
        let name: String
        var dark = false
        var empty = false
        var peek = false
        /// 試作と同じ履歴の代わりに使う履歴（試作に同じ状態がないエッジケース）
        var entries: [SampleHistory.Entry]?
        /// 一度描いた後に選ぶ項目（↓ を押したのと同じ。選んだカードが見える位置まで一覧が送られるかを確かめる）
        var selectAfterLayout: Int?
        /// 試作の 6 件の代わりに使う定型文（試作に同じ状態がないエッジケース）
        var snippets: [Snippet]?
        let setUp: (HistoryPanelModel) -> Void
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "light") { $0.select(1) },
        Scenario(name: "dark", dark: true, selectAfterLayout: 2) { _ in },
        Scenario(name: "peek-light", peek: true) { $0.select(1) },
        Scenario(name: "peek-dark", dark: true, peek: true, selectAfterLayout: 2) { _ in },
        Scenario(name: "filtered") {
            $0.setKind(.command)
            $0.setMethod(.other)
        },
        Scenario(name: "filtered-dark", dark: true) {
            $0.setKind(.command)
            $0.setMethod(.other)
        },
        Scenario(name: "search") { $0.query = "depuroi" },
        Scenario(name: "empty-search") { $0.query = "zzzz" },
        Scenario(name: "empty-search-dark", dark: true) { $0.query = "zzzz" },
        Scenario(name: "empty-history", empty: true) { _ in },
        Scenario(name: "pinned") { $0.togglePinnedOnly() },
        Scenario(name: "picker") {
            $0.openPicker()
            $0.pickerQuery = "めーる"
        },
        // 試作に同じ状態のスクショがないもの（エッジケースの確認用）
        Scenario(name: "edge-images") { $0.setKind(.image) },
        Scenario(name: "edge-peek-tall-image", peek: true) {
            $0.setKind(.image)
            $0.select(1)
        },
        Scenario(name: "edge-peek-wide-image", dark: true, peek: true) {
            $0.setKind(.image)
            $0.select(2)
        },
        Scenario(name: "edge-long-line", peek: true) {
            $0.setKind(.command)
            $0.select(2)
        },
        Scenario(name: "edge-peek-files", peek: true) { $0.setKind(.file) },
        Scenario(name: "edge-peek-url", dark: true, peek: true) { $0.setKind(.url) },
        Scenario(name: "edge-peek-color", peek: true) { $0.setKind(.color) },
        Scenario(name: "edge-peek-rich", peek: true) { $0.setKind(.richText) },
        Scenario(name: "edge-all-filters") {
            $0.setKind(.command)
            $0.setMethod(.keyboard)
            $0.setApp("com.example.terminal")
            $0.togglePinnedOnly()
            $0.query = "npm"
        },
        // フェーズ3: コードの色付けとコマンドのプロンプト・コピー元のページ（試作と同じ状態）
        Scenario(name: "code-cards-light") { $0.setKind(.code) },
        Scenario(name: "code-cards-dark", dark: true) { $0.setKind(.code) },
        Scenario(name: "peek-code-ts-dark", dark: true, peek: true) {
            $0.setKind(.code)
            $0.select(1)
        },
        // 一覧の下の方のカードは、描いた後に選ぶ（試作と同じく、選んだカードが見える位置まで一覧が送られる）
        Scenario(name: "peek-code-py-light", peek: true, selectAfterLayout: 2) { $0.setKind(.code) },
        Scenario(name: "peek-code-sh-dark", dark: true, peek: true, selectAfterLayout: 3) { $0.setKind(.code) },
        Scenario(name: "peek-cmd-light", peek: true) {
            $0.setKind(.command)
            $0.select(1)
        },
        Scenario(name: "peek-cmd-dark", dark: true, peek: true) { $0.setKind(.command) },
        // フェーズ3 のエッジケース（試作に同じ状態がないもの）
        Scenario(name: "edge-code-cards", entries: SampleHistory.edgeEntries) { $0.setKind(.code) },
        Scenario(name: "edge-peek-code-unknown", peek: true, entries: SampleHistory.edgeEntries) { $0.select(0) },
        Scenario(name: "edge-peek-code-one-char", dark: true, peek: true, entries: SampleHistory.edgeEntries) {
            $0.select(1)
        },
        Scenario(name: "edge-peek-code-cjk", peek: true, entries: SampleHistory.edgeEntries) { $0.select(2) },
        // 描いた後に選ぶ（とても長い 1 行のカードが一覧に写り、パネルの幅に収まるかも見られる。#16）
        Scenario(
            name: "edge-peek-code-long-line", dark: true, peek: true, entries: SampleHistory.edgeEntries,
            selectAfterLayout: 3
        ) { _ in },
        Scenario(name: "edge-code-cards-long-line", entries: SampleHistory.edgeEntries, selectAfterLayout: 3) {
            $0.setKind(.code)
        },
        Scenario(name: "edge-peek-code-3000-lines", peek: true, entries: SampleHistory.edgeEntries) {
            $0.select(4)
        },
        Scenario(name: "edge-peek-cmd-ps1", dark: true, peek: true, entries: SampleHistory.edgeEntries) {
            $0.select(5)
        },
        Scenario(name: "edge-peek-text-source", peek: true, entries: SampleHistory.edgeEntries) { $0.select(6) },
        Scenario(name: "edge-search-in-code", peek: true) {
            $0.setKind(.code)
            $0.query = "item"
        },
        // フェーズ7: 定型文の一覧（試作の b-snippets.png と同じく 2 件目を選ぶ）・⌘Y の定型文・検索
        Scenario(name: "snippets") {
            $0.toggleSnippets()
            $0.select(1)
        },
        // 下の方のカードは、描いた後に選ぶ（選んだカードが見える位置まで一覧が送られる。履歴と同じ）
        Scenario(name: "snippets-dark", dark: true, selectAfterLayout: 3) { $0.toggleSnippets() },
        Scenario(name: "peek-snippet-light", peek: true) { $0.toggleSnippets() },
        Scenario(name: "peek-snippet-dark", dark: true, peek: true, selectAfterLayout: 3) { $0.toggleSnippets() },
        Scenario(name: "snippets-search") {
            $0.toggleSnippets()
            $0.query = "rebyu-"
        },
        // 定型文のエッジケース（試作に無い状態）: 0 件・長い名前と本文・複数行・壊れた記法・同じ名前・数百件
        Scenario(name: "edge-snippets-empty", snippets: []) { $0.toggleSnippets() },
        Scenario(name: "edge-snippets-empty-dark", dark: true, snippets: []) { $0.toggleSnippets() },
        Scenario(name: "edge-snippets-long", peek: true, snippets: SampleHistory.edgeSnippets) {
            $0.toggleSnippets()
            $0.select(1)
        },
        Scenario(
            name: "edge-snippets-long-dark", dark: true, peek: true, selectAfterLayout: 3,
            snippets: SampleHistory.edgeSnippets
        ) { $0.toggleSnippets() },
        Scenario(
            name: "edge-snippets-many", selectAfterLayout: 150, snippets: SampleHistory.manySnippets(count: 300)
        ) { $0.toggleSnippets() },
    ]

    @Test("各状態を描き、試作と並べた比較画像を作る")
    func renderAll() async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scenario in Self.scenarios {
            let history =
                scenario.empty
                ? FakeHistory()
                : SampleHistory.make(imageDirectory: assets, entries: scenario.entries ?? SampleHistory.entries)
            if !scenario.empty { history.snippetList = scenario.snippets ?? SampleHistory.snippets }
            let model = HistoryPanelModel(actions: history)
            model.clock = { SampleHistory.now }
            model.open()
            scenario.setUp(model)
            if scenario.peek { model.setPreviewOpen(true) }
            let loader = ClipContentLoader(actions: history)
            for item in model.items where item.kind == .image {
                _ = loader.loadThumbnailNow(for: item)
                _ = loader.loadThumbnailNow(for: item, size: ClipContentLoader.previewPixelSize)
            }
            // 長いコードの色付けは裏で作るので、描く前に作り終えておく（静止画では「色なし → 色付き」の途中を撮れない）
            if scenario.peek, let item = model.selected, item.kind == .code {
                let detail = loader.detail(for: item)
                _ = await loader.codeTokens(
                    for: item, text: DisplayText.codeText(detail.fullText ?? item.previewText ?? ""))
            }
            let rep = render(
                model: model, loader: loader, dark: scenario.dark, peek: scenario.peek,
                selectAfterLayout: scenario.selectAfterLayout)
            let ours = output.appendingPathComponent("swift-\(scenario.name).png")
            try rep.representation(using: .png, properties: [:])!.write(to: ours)
            if let protoShots {
                let proto = protoShots.appendingPathComponent("\(scenario.name).png")
                if let image = NSImage(contentsOf: proto),
                    let compare = compose(proto: image, ours: rep, peek: scenario.peek)
                {
                    try compare.representation(using: .png, properties: [:])!
                        .write(to: output.appendingPathComponent("compare-\(scenario.name).png"))
                }
            }
        }
    }

    @Test("数千件の履歴で開く速さ（読み込み・絞り込み・最初の描画・検索）")
    func openSpeed() async throws {
        _ = NSApplication.shared
        func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
        var lines: [String] = []
        for count in [1000, 5000] {
            let history = SampleHistory.bulk(count: count)
            // 開いてすぐ打った場合（裏の正規化が終わる前。足りない分をその場で作る）
            let cold = HistoryPanelModel(actions: history)
            cold.clock = { SampleHistory.now }
            var start = Date()
            cold.open()
            let openTime = ms(start)
            start = Date()
            cold.query = "sample-4999"
            let coldSearch = ms(start)
            // 開いて 1 秒後に打った場合（裏の正規化が終わっている）。メインアクターを空けて待つ
            // （RunLoop を回すだけでは、裏の計算結果をメインに戻す仕事が走らない）
            let warm = HistoryPanelModel(actions: history)
            warm.clock = { SampleHistory.now }
            warm.open()
            try await Task.sleep(for: .seconds(1))
            start = Date()
            warm.query = "sample-4999"
            let warmSearch = ms(start)
            start = Date()
            warm.query = "kopi"
            let romaji = ms(start)
            warm.query = ""
            let loader = ClipContentLoader(actions: history)
            start = Date()
            _ = render(model: warm, loader: loader, dark: false, peek: false, settle: 0)
            let renderTime = ms(start)
            start = Date()
            for _ in 0..<100 { warm.move(by: 1) }
            let move = ms(start) / 100
            lines.append(
                String(
                    format:
                        "%d 件: open %.1f ms / 開いてすぐの検索 %.1f ms / 温まった後の検索 %.1f ms・ローマ字 %.1f ms / 最初の描画 %.1f ms / ↓ 1 回 %.2f ms",
                    count, openTime, coldSearch, warmSearch, romaji, renderTime, move))
            #expect(openTime < 100)
            #expect(warmSearch < 50)
        }
        try lines.joined(separator: "\n").write(
            to: output.appendingPathComponent("open-speed.txt"), atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }

    // MARK: 描画

    static let backdropLight = PanelPalette.hex(0xDFE6F0)
    static let backdropDark = PanelPalette.hex(0x10131C)

    /// 試作の切り抜きと同じ範囲（パネルの左上から 20pt 外側）を描く
    func render(
        model: HistoryPanelModel, loader: ClipContentLoader, dark: Bool, peek: Bool, settle: TimeInterval = 0.5,
        selectAfterLayout: Int? = nil
    ) -> NSBitmapImageRep {
        let backdrop = dark ? Self.backdropDark : Self.backdropLight
        let width = 20 + HistoryPanelView.size.width + (peek ? 10 + PeekView.width : 0) + 20
        let size = CGSize(width: width, height: 20 + HistoryPanelView.size.height + 20)
        let view = ZStack(alignment: .topLeading) {
            backdrop
            HStack(alignment: .top, spacing: 10) {
                HistoryPanelView(model: model, loader: loader)
                if peek { PeekView(model: model, loader: loader) }
            }
            .padding(20)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.surfaceStyle, .flat(backdrop: backdrop))
        .environment(\.appIcons, AppIconProvider(tiles: SampleHistory.iconTiles))
        .environment(\.colorScheme, dark ? .dark : .light)

        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: size.width, height: size.height), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()  // 画面の外（-10000）に出す。ScrollView の位置送りは表示中の窓でしか効かない
        host.layoutSubtreeIfNeeded()
        if settle > 0 { RunLoop.main.run(until: Date().addingTimeInterval(settle)) }
        if let selectAfterLayout {
            model.select(selectAfterLayout)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil
        return rep
    }

    /// 左に試作（HTML）、右に SwiftUI の描画を並べる（どちらも 2 倍）
    func compose(proto: NSImage, ours: NSBitmapImageRep, peek: Bool) -> NSBitmapImageRep? {
        guard
            let protoRep = proto.representations.first as? NSBitmapImageRep
                ?? NSBitmapImageRep(data: proto.tiffRepresentation!)
        else { return nil }
        let scale = 2
        let cropWidth = (20 + 372 + (peek ? 10 + 470 : 0) + 20) * scale
        let cropHeight = (20 + 528 + 20) * scale
        // 試作の切り抜き: パネルの左上（CSS 40, 40）から 20pt 外側
        guard let cg = protoRep.cgImage,
            let crop = cg.cropping(to: CGRect(x: 20 * scale, y: 20 * scale, width: cropWidth, height: cropHeight))
        else { return nil }
        let label = 64
        let gap = 24
        let width = cropWidth * 2 + gap
        let height = cropHeight + label
        guard
            let out = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.current?.cgContext.draw(crop, in: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
        if let oursCG = ours.cgImage {
            NSGraphicsContext.current?.cgContext.draw(
                oursCG, in: CGRect(x: cropWidth + gap, y: 0, width: cropWidth, height: cropHeight))
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.black,
        ]
        ("試作（HTML・ヘッドレス Chrome）" as NSString).draw(
            at: NSPoint(x: 16, y: cropHeight + 14), withAttributes: attributes)
        ("SwiftUI（オフスクリーン描画）" as NSString).draw(
            at: NSPoint(x: cropWidth + gap + 16, y: cropHeight + 14), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}

/// コードの色付けの速さ（環境変数を付けたときだけ）。字句解析・AttributedString にするまで・⌘Y のプレビューを描くまでを分けて測る
@MainActor
@Suite("色付けの速さ", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"] != nil))
struct HighlightSpeedTests {
    @Test("数百〜数千行のコードの色付けとプレビューの描画にかかる時間")
    func highlightSpeed() async throws {
        _ = NSApplication.shared
        func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
        /// 3 回描いた中央値（ほかの仕事でマシンが混んでいると 1 回ごとの値がぶれるため）
        func medianDraw(_ model: HistoryPanelModel, _ loader: ClipContentLoader) -> Double {
            let snapshot = SnapshotTests()
            let times = (0..<3).map { _ in
                let start = Date()
                _ = snapshot.render(model: model, loader: loader, dark: false, peek: true, settle: 0)
                return ms(start)
            }
            return times.sorted()[1]
        }
        var lines: [String] = []
        for count in [1, 100, 300, 500, 1000, 3000] {
            let code = SampleHistory.longSwift(lines: count)
            var start = Date()
            let language = CodeLanguageDetector.detect(String(code.prefix(Limits.default.previewCharacterLimit)))
            let detect = ms(start)
            start = Date()
            let tokens = SyntaxHighlighter.tokens(in: code, language: language)
            let tokenize = ms(start)
            start = Date()
            _ = CodeStyler.appKit(
                code, tokens: tokens, style: CodeStyler.AppKitStyle(palette: .light, css: CSS.previewCode),
                query: .empty)
            let style = ms(start)

            // ⌘Y のプレビュー: 開いて最初の 1 枚を描くまで（短いものはその場で色付け、長いものは色なしで先に出る）
            let entry = SampleHistory.Entry(
                kind: .code, minutesAgo: 1, app: "xcode", method: .keyboard, body: .code(code))
            let history = SampleHistory.make(entries: [entry])
            let model = HistoryPanelModel(actions: history)
            model.clock = { SampleHistory.now }
            model.open()
            model.setPreviewOpen(true)
            let loader = ClipContentLoader(actions: history)
            start = Date()
            _ = SnapshotTests().render(model: model, loader: loader, dark: false, peek: true, settle: 0)
            let firstDraw = ms(start)
            // 裏の色付けが済んだ後の描き直し（キャッシュにある状態で）
            // プレビューに出すのは先頭 2 万文字まで（ClipContentLoader.previewCharacterLimit）
            let text = DisplayText.codeText(String(code.prefix(ClipContentLoader.previewCharacterLimit)))
            if let item = model.selected {
                _ = await loader.codeTokens(for: item, text: text)
            }
            let redraw = medianDraw(model, loader)
            lines.append(
                String(
                    format:
                        "%d 行（%d 文字・%d 区間）: 判定 %.2f ms / 字句解析 %.1f ms / 色付きの文字列 %.1f ms / パネルとプレビューの最初の描画 %.1f ms / 色付きで描き直し（3 回の中央値）%.1f ms（プレビューは先頭 %d 文字）",
                    count, code.utf16.count, tokens.count, detect, tokenize, style, firstDraw, redraw,
                    text.utf16.count))
        }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"]!)
        try lines.joined(separator: "\n").write(
            to: output.appendingPathComponent("highlight-speed.txt"), atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }
}

/// 実際のストア（SQLite）から数千件を読む速さ（環境変数を付けたときだけ）
@MainActor
@Suite("ストアから読む速さ", .enabled(if: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"] != nil))
struct StoreSpeedTests {
    @Test("5000 件をストアに入れて、一覧の読み込み（メタデータと平文）にかかる時間")
    func readSpeed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "makurip-speed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = Limits(
            maxItems: 10_000, maxTotalBytes: Limits.default.maxTotalBytes,
            maxRepresentationBytes: Limits.default.maxRepresentationBytes, maxClipBytes: Limits.default.maxClipBytes,
            inlineThresholdBytes: Limits.default.inlineThresholdBytes,
            previewCharacterLimit: Limits.default.previewCharacterLimit)
        let store = try ClipStore(directory: directory, limits: limits)
        let body = String(repeating: "テスト用の文章 sample text。", count: 40)
        for index in 0..<5000 {
            let snapshot = PasteboardSnapshot(items: [
                PasteboardItemSnapshot(representations: [
                    PasteboardRepresentation(type: PasteboardTypes.utf8PlainText, data: Data("\(index) \(body)".utf8))
                ])
            ])
            let context = CapturePipeline.Context(
                now: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                frontmostApp: SourceApp(bundleID: "com.example.app\(index % 9)", name: "App"), copyMethod: .keyboard)
            guard case .accept(let clip) = CapturePipeline.process(snapshot, context: context, limits: limits) else {
                continue
            }
            _ = try store.save(clip)
        }
        let start = Date()
        let items = try store.items(limit: HistoryPanelModel.loadLimit)
        let elapsed = Date().timeIntervalSince(start) * 1000
        let line = String(format: "ストアから %d 件を読む: %.1f ms", items.count, elapsed)
        print(line)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"]!)
        try line.write(to: output.appendingPathComponent("store-speed.txt"), atomically: true, encoding: .utf8)
        #expect(items.count == 5000)
        #expect(elapsed < 300)
    }
}
