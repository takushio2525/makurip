import AppKit
import Foundation
import MakuripCore
import SwiftUI
import Testing

@testable import MakuripUI

/// 定型文の窓をオフスクリーンで PNG に描く。試作に定型文の窓はないので、見た目の元にした試作の設定シート
/// （`settings-states.html`）と並べる。環境変数を付けたときだけ動く（`make ui-compare`）
@MainActor
@Suite(
    "定型文の窓のオフスクリーン描画", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"] != nil))
struct SnippetEditorSnapshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"] ?? "/dev/null")
    let protoShots = ProcessInfo.processInfo.environment["MAKURIP_PROTO_SHOTS"].map { URL(fileURLWithPath: $0) }

    static let size = CGSize(width: SnippetEditorCSS.width, height: SnippetEditorCSS.height)

    struct Scenario {
        let name: String
        /// 並べる試作の設定シート
        var proto: String?
        var dark = false
        var snippets: [Snippet] = SampleHistory.snippets
        /// 定型文のファイルにそのまま書く JSON（読めない項目の注記）
        var rawFile: String?
        let setUp: (SnippetEditorModel) -> Void
    }

    static let scenarios: [Scenario] = [
        // 差し込みのある定型文を編集（試作の 4 件目「コードブロックで囲む」）
        Scenario(name: "snippet-editor-light", proto: "settings-behavior-light") {
            $0.open(.edit(SampleHistory.snippets[3].id))
        },
        Scenario(name: "snippet-editor-dark", proto: "settings-behavior-dark", dark: true) {
            $0.open(.edit(SampleHistory.snippets[0].id))
        },
        // 履歴から登録（本文だけ入った新しい下書き）
        Scenario(name: "snippet-editor-new-light", proto: "settings-behavior-light") {
            $0.open(.new(body: "$ swift test --filter SnippetTests\n$ make check"))
        },
        Scenario(name: "snippet-editor-new-dark", proto: "settings-behavior-dark", dark: true) {
            $0.open(.new(body: ""))
        },
        // エッジケース: 保存できない（本文が空）・0 件・読めない項目・長いもの・数百件
        Scenario(name: "edge-snippet-editor-error") {
            $0.open(.edit(SampleHistory.snippets[1].id))
            $0.draft.body = "  "
            $0.save()
        },
        Scenario(name: "edge-snippet-editor-empty-dark", dark: true, snippets: []) {
            $0.open(.open)
            $0.cancel()
        },
        Scenario(
            name: "edge-snippet-editor-issues",
            rawFile: #"{"snippets":[{"name":"使える","body":"{{日付}}"},{"name":"本文なし"},{"body":"  "}]}"#
        ) { $0.open(.open) },
        Scenario(name: "edge-snippet-editor-long", dark: true, snippets: SampleHistory.edgeSnippets) {
            $0.open(.edit(SampleHistory.edgeSnippets[6].id))
        },
        Scenario(name: "edge-snippet-editor-many", snippets: SampleHistory.manySnippets(count: 300)) {
            $0.open(.open)
            for _ in 0..<40 { $0.selectNeighbor(1) }
        },
    ]

    @Test("定型文の窓を描き、試作の設定シートと並べる")
    func renderAll() throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scenario in Self.scenarios {
            let dir = SettingsTempDirectory()
            let file = SnippetFile(directory: dir.url)
            if let raw = scenario.rawFile {
                try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
                try Data(raw.utf8).write(to: file.url)
            } else {
                try file.save(SnippetCollection(scenario.snippets))
            }
            let controller = SnippetController(file: file)
            let model = SnippetEditorModel(
                controller: controller, environment: SnippetEditorEnvironment(dateFormat: { .slash }))
            let rep = render(model: model, dark: scenario.dark, setUp: scenario.setUp)
            try rep.representation(using: .png, properties: [:])?.write(
                to: output.appendingPathComponent("swift-\(scenario.name).png"))
            if let protoName = scenario.proto, let protoShots,
                let proto = NSImage(contentsOf: protoShots.appendingPathComponent("\(protoName).png")),
                let compare = compose(proto: proto, ours: rep)
            {
                try compare.representation(using: .png, properties: [:])?.write(
                    to: output.appendingPathComponent("compare-\(scenario.name).png"))
            }
            model.detach()
        }
    }

    /// 本文（NSTextView）は SwiftUI のフォーカスの外なので、頼みが届くかを窓に載せて確かめる（窓を作るので描画と一緒に動かす）
    @Test("本文の入力欄にフォーカスが届く（新しい下書き・差し込みの札）。名前の入力欄へも移せる")
    func bodyFocus() throws {
        _ = NSApplication.shared
        let dir = SettingsTempDirectory()
        let controller = SnippetController(file: SnippetFile(directory: dir.url))
        try controller.add(SnippetDraft(name: "a", body: "x"))
        let model = SnippetEditorModel(controller: controller)
        let host = NSHostingView(rootView: SnippetEditorView(model: model).frame(width: 680, height: 560))
        host.frame = CGRect(x: 0, y: 0, width: 680, height: 560)
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 680, height: 560), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        model.open(.open)
        settle()
        #expect(!model.bodyFocused)
        model.beginNew()
        settle()
        #expect(model.bodyFocused)
        #expect(window.firstResponder is SnippetBodyTextView)
        model.select(controller.snippets[0].id)
        settle()
        model.bodySelection = NSRange(location: 1, length: 0)
        model.insert(.date)
        settle()
        #expect(model.bodyFocused)
        #expect(model.draft.body == "x{{日付}}")
        #expect((window.firstResponder as? NSTextView)?.string == "x{{日付}}")
        // 名前の検証に通らないときは名前の入力欄へ（SwiftUI のフォーカス）
        model.draft.name = String(repeating: "n", count: 101)
        model.save()
        settle()
        #expect(!model.bodyFocused)
    }

    func render(model: SnippetEditorModel, dark: Bool, setUp: (SnippetEditorModel) -> Void) -> NSBitmapImageRep {
        let backdrop = dark ? SnapshotTests.backdropDark : SnapshotTests.backdropLight
        let size = CGSize(width: 20 + Self.size.width + 20, height: 20 + Self.size.height + 20)
        let view = ZStack(alignment: .topLeading) {
            backdrop
            SnippetEditorView(model: model)
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(
                        Color.black.opacity(0.25), lineWidth: 0.5)
                )
                .padding(20)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, dark ? .dark : .light)

        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: size.width, height: size.height), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        setUp(model)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil
        return rep
    }

    /// 左に試作の設定シート（見た目の元）、右に定型文の窓。どちらも 2 倍・上ぞろえ
    func compose(proto: NSImage, ours: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard
            let protoRep = proto.representations.first as? NSBitmapImageRep
                ?? NSBitmapImageRep(data: proto.tiffRepresentation!),
            let cg = protoRep.cgImage, let oursCG = ours.cgImage
        else { return nil }
        let scale = 2
        let protoWidth = (20 + Int(SettingsSnapshotTests.sheetSize.width) + 20) * scale
        let protoHeight = (20 + Int(SettingsSnapshotTests.sheetSize.height) + 20) * scale
        guard let crop = cg.cropping(to: CGRect(x: 380 * scale, y: 20 * scale, width: protoWidth, height: protoHeight))
        else { return nil }
        let label = 64
        let gap = 24
        let width = protoWidth + gap + oursCG.width
        let height = max(protoHeight, oursCG.height) + label
        guard
            let out = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let top = height - label
        NSGraphicsContext.current?.cgContext.draw(
            crop, in: CGRect(x: 0, y: top - protoHeight, width: protoWidth, height: protoHeight))
        NSGraphicsContext.current?.cgContext.draw(
            oursCG, in: CGRect(x: protoWidth + gap, y: top - oursCG.height, width: oursCG.width, height: oursCG.height))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.black,
        ]
        ("試作の設定シート（定型文の窓は試作に無い。見た目の元）" as NSString).draw(
            at: NSPoint(x: 16, y: top + 14), withAttributes: attributes)
        ("SwiftUI の定型文の窓（オフスクリーン描画）" as NSString).draw(
            at: NSPoint(x: protoWidth + gap + 16, y: top + 14), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
