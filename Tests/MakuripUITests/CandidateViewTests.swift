import Foundation
import MakuripCore
import Testing

@testable import MakuripUI

@Suite("候補窓の行の文言")
struct CandidateRowTextTests {
    func item(_ kind: ClipKind, _ text: String?, items: Int = 1, source: String? = "メモ") -> ClipItem {
        ClipItem(
            id: UUID(), contentHash: "h", kind: kind, copyMethod: .keyboard,
            source: SourceApp(bundleID: "com.example.app", name: source), sourceURL: nil, createdAt: SampleHistory.now,
            lastUsedAt: SampleHistory.now, copyCount: 1, isPinned: false, flags: [], previewText: text, totalBytes: 1,
            pasteboardItemCount: items)
    }

    @Test("右の薄い字（試作の sub と同じ決まり）")
    func details() {
        #expect(CandidateRowText.detail(item(.code, "a\nb\nc")) == "コード 3行")
        // 言語が分かれば言語名（試作の「Swift 17行」）
        #expect(CandidateRowText.detail(item(.code, "a\nb\nc"), language: .swift) == "Swift 3行")
        #expect(CandidateRowText.detail(item(.code, "a"), language: .shell) == "シェル 1行")
        #expect(CandidateRowText.detail(item(.command, "$ git status")) == "コマンド")
        #expect(CandidateRowText.detail(item(.command, "$ a\n$ b")) == "コマンド 2行")
        #expect(CandidateRowText.detail(item(.text, "短い文")) == "テキスト")
        #expect(CandidateRowText.detail(item(.text, String(repeating: "あ", count: 41))) == "テキスト 41字")
        #expect(CandidateRowText.detail(item(.text, "1 行目\n2 行目")) == "テキスト 9字")
        #expect(CandidateRowText.detail(item(.richText, "見出し")) == "リッチテキスト")
        #expect(CandidateRowText.detail(item(.image, nil)) == "画像")
        #expect(
            CandidateRowText.detail(item(.image, nil), imageSize: CGSize(width: 1600, height: 1000)) == "画像 1600×1000")
        #expect(CandidateRowText.detail(item(.file, "a.pdf\nb.pdf\nc.mov", items: 3)) == "ファイル 3件")
        #expect(CandidateRowText.detail(item(.file, "a.pdf")) == "ファイル")
        #expect(CandidateRowText.detail(item(.url, "https://example.com")) == "URL")
        #expect(CandidateRowText.detail(item(.color, "#0A84FF")) == "色")
        // 一覧用の平文（先頭 1000 文字）で切れているときは「+」
        let long = String(repeating: "x\n", count: 500)
        #expect(CandidateRowText.detail(item(.code, long)) == "コード 501+行")
    }

    @Test("1 行目: コマンドの「$ 」を分ける・コードは最初の空でない行・URL は題名・画像はコピー元のアプリから")
    func titles() {
        #expect(
            CandidateRowText.title(item(.command, "$ brew install swiftlint\n$ x"))
                == .init(prompt: "$", body: "brew install swiftlint", mono: true))
        #expect(
            CandidateRowText.title(item(.command, "% npm run build"))
                == .init(prompt: "%", body: "npm run build", mono: true))
        #expect(CandidateRowText.title(item(.command, "ls -la")) == .init(body: "ls -la", mono: true))
        #expect(CandidateRowText.title(item(.code, "\n\n    struct A {\n}")) == .init(body: "struct A {", mono: true))
        #expect(
            CandidateRowText.title(item(.url, "https://example.com/a"), urlTitle: "例のページ")
                == .init(body: "例のページ", mono: false))
        #expect(
            CandidateRowText.title(item(.url, "https://example.com/a")) == .init(body: "example.com/a", mono: false))
        #expect(CandidateRowText.title(item(.image, nil, source: "スクリーンショット")).body == "スクリーンショットの画像")
        #expect(CandidateRowText.title(item(.image, nil, source: "Safari")).body == "Safari の画像")
        #expect(CandidateRowText.title(item(.image, nil, source: nil)).body == "画像")
        #expect(CandidateRowText.title(item(.file, "企画書.pdf\nb"), fileName: "企画書.pdf").body == "企画書.pdf")
        #expect(
            CandidateRowText.title(item(.color, "#0a84ff"), colorHex: "#0A84FF") == .init(body: "#0A84FF", mono: true))
        #expect(CandidateRowText.title(item(.text, "   \n  ")).body == "（空白だけ）")
    }
}

@MainActor
@Suite("候補窓の画面の状態")
struct CandidateViewModelTests {
    static let items = SampleHistory.make().items

    func state(_ index: Int, order: CandidateOrder = .terminal, session: Int = 1, note: CandidateNote? = nil)
        -> CandidateViewState
    {
        CandidateViewState(
            sessionID: session, items: Self.items, selectedIndex: index, order: order, note: note, target: nil)
    }

    @Test("ターミナル式: 最新がいちばん下の行。↑ でたどっても選んだ行はいちばん下のまま一覧が流れる（試作と同じ）")
    func terminalRows() {
        let model = CandidateViewModel(keymap: .default)
        model.update(state(0))
        let count = Self.items.count
        #expect(model.firstVisibleRow == count - 8)
        #expect(model.visibleRows.map(\.index) == [7, 6, 5, 4, 3, 2, 1, 0])
        #expect(model.selectedVisibleRow == 7)
        #expect(model.rowOffset == CandidateLayout.rowOffset(visibleRow: 7))
        #expect(model.positionText == "1 / \(count)")
        model.update(state(3))
        #expect(model.visibleRows.map(\.index) == [10, 9, 8, 7, 6, 5, 4, 3])
        #expect(model.selectedVisibleRow == 7, "窓は動かない（選んだ行がカーソルの行にとどまる）")
        // いちばん古いほうの 8 行に入ると、選んだ行が上へ動く
        model.update(state(count - 1))
        #expect(model.firstVisibleRow == 0)
        #expect(model.selectedVisibleRow == 0)
    }

    @Test("予測変換式: 最新がいちばん上の行")
    func imeRows() {
        let model = CandidateViewModel(keymap: .default)
        model.update(state(0, order: .ime))
        #expect(model.visibleRows.map(\.index) == Array(0..<8))
        #expect(model.selectedVisibleRow == 0)
        model.update(state(5, order: .ime))
        #expect(model.selectedVisibleRow == 5)
        model.update(state(9, order: .ime))
        #expect(model.visibleRows.last?.index == 9)
        #expect(model.selectedVisibleRow == 7)
    }

    @Test("0 件・注記ありの窓の大きさ")
    func sizes() {
        let model = CandidateViewModel(keymap: .default)
        model.update(
            CandidateViewState(sessionID: 1, items: [], selectedIndex: 0, order: .terminal, note: nil, target: nil))
        #expect(model.isEmpty)
        #expect(model.visibleRows.isEmpty)
        #expect(model.rowOffset == CandidateLayout.emptyRowOffset)
        #expect(model.windowSize.height == CandidateLayout.windowHeight(rowCount: 0, hasNote: false))
        model.update(state(0, note: .deferredApp))
        #expect(
            model.windowSize == CGSize(width: 372, height: CandidateLayout.windowHeight(rowCount: 8, hasNote: true)))
    }

    @Test("揺らす合図")
    func bump() {
        let model = CandidateViewModel(keymap: .default)
        model.bump()
        model.bump()
        #expect(model.shakeCount == 2)
    }
}
