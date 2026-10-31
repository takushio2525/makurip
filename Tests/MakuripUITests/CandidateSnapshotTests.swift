import AppKit
import Foundation
import MakuripCore
import SwiftUI
import Testing

@testable import MakuripUI

/// 候補窓をオフスクリーンで PNG に描き、試作のスクショと並べた比較画像を作る（見た目の検証用。位置は比べない）。
///
/// 環境変数を付けたときだけ動く（`make ui-compare`。変数の意味は `SnapshotTests` と同じ）。
/// 試作側は `design/ui-compare/candidate-states.html` で、候補窓を CSS の (40, 40) に固定し、ぼかしを切って撮ったもの
@MainActor
@Suite(
    "候補窓のオフスクリーン描画", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"] != nil))
struct CandidateSnapshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"] ?? "/dev/null")
    let assets = ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_ASSETS"].map { URL(fileURLWithPath: $0) }
    let protoShots = ProcessInfo.processInfo.environment["MAKURIP_PROTO_SHOTS"].map { URL(fileURLWithPath: $0) }

    struct Scenario {
        let name: String
        var dark = false
        var order = CandidateOrder.terminal
        /// 選ぶ項目（新しい順の添字）。0 から 1 つずつたどったのと同じ見える範囲になる
        var index = 0
        var note: CandidateNote?
        /// 履歴の件数（nil はすべて）
        var count: Int?
    }

    /// 名前は design/ui-compare/shoot.sh の試作側と同じ（試作に無いものは swift-*.png だけ作る）
    static let scenarios: [Scenario] = [
        Scenario(name: "candidate-light", index: 3),  // URL（試作の candidate-light と同じ選択）
        Scenario(name: "candidate-dark", dark: true, index: 2),  // 画像（試作の candidate-dark と同じ選択）
        Scenario(name: "candidate-image", index: 7),  // 縦長の画像
        Scenario(name: "candidate-long", index: 12),  // 長い 1 行のコマンド（見える範囲を送った後）
        Scenario(name: "candidate-scrolled-dark", dark: true, index: 15),  // 長い文章
        Scenario(name: "candidate-ime", order: .ime),
        Scenario(name: "candidate-empty", count: 0),
        Scenario(name: "candidate-one", count: 1),
        Scenario(name: "candidate-deferred-dark", dark: true, index: 1, note: .deferredApp),
        Scenario(name: "candidate-composing", index: 6, note: .composing),
    ]

    @Test("各状態を描き、試作と並べた比較画像を作る")
    func renderAll() throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let history = SampleHistory.make(imageDirectory: assets)
        for scenario in Self.scenarios {
            let items = scenario.count.map { Array(history.items.prefix($0)) } ?? history.items
            let model = CandidateViewModel(keymap: .default)
            let loader = ClipContentLoader(actions: history)
            for item in items where item.kind == .image {
                _ = loader.loadThumbnailNow(for: item, size: CandidateRowView.thumbnailPixels)
            }
            // 始めた状態から 1 つずつたどる（見える範囲の送り方を本番と同じにする）
            for index in 0...min(scenario.index, max(0, items.count - 1)) {
                model.update(
                    CandidateViewState(
                        sessionID: 1, items: items, selectedIndex: index, order: scenario.order, note: scenario.note,
                        target: nil))
            }
            let rep = render(model: model, loader: loader, dark: scenario.dark)
            try rep.representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent("swift-\(scenario.name).png"))
            if let protoShots,
                let proto = NSImage(contentsOf: protoShots.appendingPathComponent("\(scenario.name).png")),
                let compare = compose(proto: proto, ours: rep, height: model.windowSize.height)
            {
                try compare.representation(using: .png, properties: [:])!
                    .write(to: output.appendingPathComponent("compare-\(scenario.name).png"))
            }
        }
    }

    /// 窓の左上から 20pt 外側までを描く（試作の切り抜きと同じ範囲）
    func render(model: CandidateViewModel, loader: ClipContentLoader, dark: Bool) -> NSBitmapImageRep {
        let backdrop = dark ? SnapshotTests.backdropDark : SnapshotTests.backdropLight
        let size = CGSize(width: model.windowSize.width + 40, height: model.windowSize.height + 40)
        let view = ZStack(alignment: .topLeading) {
            backdrop
            CandidateView(model: model, loader: loader).padding(20)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.surfaceStyle, .flat(backdrop: backdrop))
        .environment(\.colorScheme, dark ? .dark : .light)

        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: size.width, height: size.height), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()  // 画面の外（-10000）に出す
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil
        return rep
    }

    /// 左に試作（HTML）、右に SwiftUI を並べる（どちらも 2 倍）
    func compose(proto: NSImage, ours: NSBitmapImageRep, height: CGFloat) -> NSBitmapImageRep? {
        guard
            let protoRep = proto.representations.first as? NSBitmapImageRep
                ?? NSBitmapImageRep(data: proto.tiffRepresentation!),
            let cg = protoRep.cgImage
        else { return nil }
        let scale = 2
        let cropWidth = Int(CandidateLayout.width + 40) * scale
        let cropHeight = Int((height + 40).rounded(.up)) * scale
        guard let crop = cg.cropping(to: CGRect(x: 20 * scale, y: 20 * scale, width: cropWidth, height: cropHeight))
        else { return nil }
        let label = 64
        let gap = 24
        let width = cropWidth * 2 + gap
        let total = cropHeight + label
        guard
            let out = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: total, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: total).fill()
        let context = NSGraphicsContext.current?.cgContext
        context?.draw(crop, in: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
        if let oursCG = ours.cgImage {
            context?.draw(
                oursCG,
                in: CGRect(
                    x: cropWidth + gap, y: cropHeight - oursCG.height, width: oursCG.width, height: oursCG.height))
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.black,
        ]
        ("試作（HTML）" as NSString).draw(at: NSPoint(x: 16, y: cropHeight + 16), withAttributes: attributes)
        ("SwiftUI（オフスクリーン）" as NSString).draw(
            at: NSPoint(x: cropWidth + gap + 16, y: cropHeight + 16), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
