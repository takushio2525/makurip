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
        /// 一度描いた後に選ぶ項目（↓ を押したのと同じ。選んだカードが見える位置まで一覧が送られるかを確かめる）
        var selectAfterLayout: Int?
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
    ]

    @Test("各状態を描き、試作と並べた比較画像を作る")
    func renderAll() throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scenario in Self.scenarios {
            let history = scenario.empty ? FakeHistory() : SampleHistory.make(imageDirectory: assets)
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

    @Test("数千件の履歴で開く速さ（読み込み・絞り込み・最初の描画）")
    func openSpeed() throws {
        _ = NSApplication.shared
        var lines: [String] = []
        for count in [1000, 5000] {
            let history = SampleHistory.bulk(count: count)
            let model = HistoryPanelModel(actions: history)
            model.clock = { SampleHistory.now }
            let loader = ClipContentLoader(actions: history)
            let openStart = Date()
            model.open()
            let openTime = Date().timeIntervalSince(openStart)
            let searchStart = Date()
            model.query = "sample-4999"
            let searchTime = Date().timeIntervalSince(searchStart)
            let romajiStart = Date()
            model.query = "kopi"
            let romajiTime = Date().timeIntervalSince(romajiStart)
            model.query = ""
            let renderStart = Date()
            _ = render(model: model, loader: loader, dark: false, peek: false, settle: 0)
            let renderTime = Date().timeIntervalSince(renderStart)
            let moveStart = Date()
            for _ in 0..<100 { model.move(by: 1) }
            let moveTime = Date().timeIntervalSince(moveStart) / 100
            lines.append(
                String(
                    format: "%d 件: open %.1f ms / 検索 1 語 %.1f ms / ローマ字 %.1f ms / 最初の描画 %.1f ms / ↓ 1 回 %.2f ms",
                    count, openTime * 1000, searchTime * 1000, romajiTime * 1000, renderTime * 1000, moveTime * 1000))
            #expect(openTime < 0.5)
            #expect(searchTime < 0.2)
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
