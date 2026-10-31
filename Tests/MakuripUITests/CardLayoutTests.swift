import AppKit
import MakuripCore
import SwiftUI
import Testing

@testable import MakuripUI

/// カードがパネルの内幅に収まること（長い 1 行で右へはみ出さない。#16）。
/// はみ出すと、カードの右の枠線と ⌘1〜9 の札がパネルの端で切れて見えなくなる
@MainActor
@Suite("カードの幅")
struct CardLayoutTests {
    nonisolated static let longLine =
        "export function relativeTime(date: Date, now = new Date()): string { return "
        + String(repeating: "value + ", count: 40) + "0 }"

    /// 長い 1 行・空白のない長い語を含む中身（種類ごと）
    nonisolated static let cases: [(ClipKind, String)] = [
        (.code, longLine + "\n  const min = 1;\n}"),
        (.code, String(repeating: "a", count: 2000)),
        (.code, "let 見出し = \"" + String(repeating: "クリップボード履歴", count: 40) + "\""),
        (.command, "$ xcodebuild " + String(repeating: "-flag value ", count: 60)),
        (.command, "$ curl https://example.com/" + String(repeating: "p", count: 600)),
        (.text, String(repeating: "長い文章の例です。", count: 120)),
        (.text, String(repeating: "w", count: 3000)),
        (.richText, String(repeating: "r", count: 3000)),
        (.url, "https://example.com/" + String(repeating: "segment/", count: 200)),
        (.file, String(repeating: "とても長いファイル名", count: 30) + ".pdf"),
        (.color, "#0A84FF"),
    ]

    @Test("長い 1 行を含むカードも、パネルが渡した幅を超えない（選択中・非選択、ライト・ダーク）", arguments: cases.indices)
    func cardFitsPanelWidth(_ index: Int) {
        let (kind, text) = Self.cases[index]
        let item = makeItem(kind, text)
        let loader = ClipContentLoader(actions: nil)
        let width = HistoryPanelView.cardWidth
        for dark in [false, true] {
            for selected in [false, true] {
                let card = CardView(
                    item: item, index: 1, isSelected: selected, query: .empty, now: SampleHistory.now,
                    quickHeld: false, quickCombo: Keymap.default.primary(.quickPaste), loader: loader
                )
                .environment(\.palette, dark ? .dark : .light)
                let size = NSHostingController(rootView: card).sizeThatFits(
                    in: CGSize(width: width, height: 10_000))
                #expect(
                    size.width <= width + 0.5,
                    "\(kind) \(dark ? "ダーク" : "ライト") \(selected ? "選択中" : "非選択") の幅 \(size.width) が \(width) を超えた")
            }
        }
    }
}
