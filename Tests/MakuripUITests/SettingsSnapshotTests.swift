import AppKit
import Foundation
import MakuripCore
import SwiftUI
import Testing

@testable import MakuripUI

/// 設定画面をオフスクリーンで PNG に描き、試作の設定シート（`design/ui-compare/settings-states.html`）と並べる。
/// 環境変数を付けたときだけ動く（`make ui-compare`。`SnapshotTests` と同じ）。
///
/// 試作のシートは画面（1440×900）の中央・幅 640・高さ 820。切り抜きはシートの左上から 20pt 外側（680×860）
@MainActor
@Suite(
    "設定画面のオフスクリーン描画", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"] != nil))
struct SettingsSnapshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAKURIP_SNAPSHOT_DIR"] ?? "/dev/null")
    let protoShots = ProcessInfo.processInfo.environment["MAKURIP_PROTO_SHOTS"].map { URL(fileURLWithPath: $0) }

    static let sheetSize = CGSize(width: 640, height: 820)

    struct Scenario {
        let name: String
        /// 並べる試作のスクショ（なければ SwiftUI だけ）
        var proto: String?
        var dark = false
        /// 設定ファイルに先に書いておく値（重なり・アプリの札などのエッジケース）
        var file: [String: JSONValue] = [:]
        let setUp: (SettingsModel) -> Void
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "settings-behavior-light", proto: "settings-behavior-light") { _ in },
        Scenario(name: "settings-behavior-dark", proto: "settings-behavior-dark", dark: true) { _ in },
        Scenario(name: "settings-keys-light", proto: "settings-keys-light") { recordMethod($0) },
        Scenario(name: "settings-keys-dark", proto: "settings-keys-dark", dark: true) { recordMethod($0) },
        // 試作に無い状態: キーが重なった（設定ファイルや CLI の --take-over なしで重なったもの）
        Scenario(
            name: "edge-settings-conflict-light",
            file: ["keys.method": .array([.string("⌘E")]), "keys.openList": .array([])]
        ) { scroll($0, to: SettingID.keys(.chooseApp)) },
        Scenario(name: "edge-settings-conflict-dark", dark: true, file: ["keys.method": .array([.string("⌘E")])]) {
            scroll($0, to: SettingID.keys(.chooseApp))
        },
        // 試作に無い項目: 件数・容量・記録しないアプリ・確定まで貼らないアプリ（札）・詳細
        Scenario(
            name: "edge-settings-history-light",
            file: [
                "maxItems": .int(200), "excludedApps": .array([.string("com.apple.Safari")]),
                "candPasteTiming": .object(["com.apple.Terminal": .string("immediate")]),
            ]
        ) { scroll($0, to: SettingID.pasteTiming) },
        Scenario(name: "edge-settings-history-dark", dark: true, file: ["maxItems": .int(200)]) {
            scroll($0, to: SettingID.idleTimeout)
            $0.beginEditing(SettingID.idleTimeout)
        },
        // 定型文の日付の書き方（#7 で足した「定型文」のまとまり）
        Scenario(name: "edge-settings-snippet", file: ["snippetDateFormat": .string("japanese")]) {
            scroll($0, to: SettingID.snippetDateFormat)
        },
        // 変えた直後の知らせ（下の段）
        Scenario(name: "edge-settings-message") { $0.choose(SettingID.candidateOrder, "ime") },
        // 設定ファイルに読めない値があったときの注記（変えるとファイルを書き直すので、何も変えずに写す）
        Scenario(
            name: "edge-settings-file-issue", dark: true,
            file: ["maxItems": .string("たくさん"), "keys.open": .array([.string("V")])]
        ) { _ in },
    ]

    static func recordMethod(_ model: SettingsModel) {
        scroll(model, to: SettingID.keys(.cycleMethod))
        model.startRecording(SettingID.keys(.cycleMethod))
    }

    static func scroll(_ model: SettingsModel, to id: String) {
        model.select(id)
        model.move(by: 0)
    }

    @Test("試作の設定シートと並べる")
    func renderAll() throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scenario in Self.scenarios {
            let dir = SettingsTempDirectory()
            let file = SettingsFile(directory: dir.url)
            if !scenario.file.isEmpty {
                try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
                let root: JSONValue = .object(["formatVersion": .int(1), "settings": .object(scenario.file)])
                try JSONEncoder().encode(root).write(to: file.url)
            }
            let model = SettingsModel(controller: SettingsController(file: file))
            model.open()
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

    func render(model: SettingsModel, dark: Bool, setUp: (SettingsModel) -> Void) -> NSBitmapImageRep {
        let backdrop = dark ? SnapshotTests.backdropDark : SnapshotTests.backdropLight
        let size = CGSize(width: 20 + Self.sheetSize.width + 20, height: 20 + Self.sheetSize.height + 20)
        let view = ZStack(alignment: .topLeading) {
            backdrop
            SettingsView(model: model)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
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
        window.orderFrontRegardless()  // 画面の外。ScrollView の位置送りは表示中の窓でしか効かない
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        setUp(model)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil
        return rep
    }

    /// 左に試作、右に SwiftUI（どちらも 2 倍）。試作はシートの左上（CSS 400, 40）から 20pt 外側を切り抜く
    func compose(proto: NSImage, ours: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard
            let protoRep = proto.representations.first as? NSBitmapImageRep
                ?? NSBitmapImageRep(data: proto.tiffRepresentation!),
            let cg = protoRep.cgImage
        else { return nil }
        let scale = 2
        let cropWidth = (20 + Int(Self.sheetSize.width) + 20) * scale
        let cropHeight = (20 + Int(Self.sheetSize.height) + 20) * scale
        guard let crop = cg.cropping(to: CGRect(x: 380 * scale, y: 20 * scale, width: cropWidth, height: cropHeight))
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
