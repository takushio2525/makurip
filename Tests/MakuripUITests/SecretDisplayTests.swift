import AppKit
import Foundation
import MakuripCore
import SwiftUI
import Testing

@testable import MakuripUI

/// 秘密の項目の表示（伏せ字・⌥ で表示・候補窓の行・カードの幅）
@MainActor
@Suite("秘密の表示")
struct SecretDisplayTests {
    let history = SampleHistory.make(entries: SampleHistory.secretEntries)

    var secretKey: ClipItem { history.items[4] }
    var secretExport: ClipItem { history.items.first { $0.kind == .command && $0.isSecretLikely }! }
    /// 本当の中身（見本データの中の偽物）
    func realText(_ item: ClipItem) -> String {
        String(
            data: history.representationData(itemID: item.id, itemIndex: 0, type: PasteboardTypes.utf8PlainText)!,
            encoding: .utf8)!
    }

    @Test("一覧用の平文は伏せ字（試作の sk-test-••••••••••••••••0000 と同じ形）")
    func maskedPreview() {
        #expect(secretKey.isSecretLikely)
        #expect(secretKey.previewText == "sk-test-" + String(repeating: "•", count: 16) + "0000")
        #expect(secretExport.previewText?.hasPrefix("export API_TOKEN=••••") == true)
        #expect(!(secretExport.previewText ?? "").contains("tok-test-"))
    }

    @Test("読み込み係: 本当の中身・伏せ字・理由・文字数。閉じたら捨てる")
    func loaderSecret() {
        let loader = ClipContentLoader(actions: history)
        let secret = loader.secret(for: secretKey)
        #expect(secret.text == realText(secretKey))
        #expect(secret.masked == secretKey.previewText)
        #expect(secret.reason == "API キーの形式")
        #expect(secret.characterCount == 36)
        #expect(DisplayText.secretInfo(reason: secret.reason, characters: secret.characterCount) == "API キーの形式 · 36 文字")
        #expect(loader.secret(for: secretExport).reason == "トークンらしき値")
        let reads = history.dataReads
        _ = loader.secret(for: secretKey)
        #expect(history.dataReads == reads, "2 回目はキャッシュから")
        loader.purgeSecrets()
        _ = loader.secret(for: secretKey)
        #expect(history.dataReads > reads, "捨てたあとは読み直す")
    }

    @Test("判定したのに読んだ文字に秘密が見つからないときは、全体を伏せる")
    func maskedFallback() {
        var item = history.items[5]  // ふつうの文章に、秘密の印だけ付けたもの
        item.flags = [.secretLikely]
        let secret = ClipContentLoader(actions: history).secret(for: item)
        #expect(secret.masked == String(repeating: "•", count: 16))
        #expect(secret.reason == "秘密らしき値")
    }

    @Test("⌥ を押している間だけ表示の状態。開き直すと隠した状態に戻る")
    func revealState() {
        let model = HistoryPanelModel(actions: history)
        model.open()
        model.select(4)
        #expect(!model.isRevealing)
        #expect(model.debugState["selectedSecret"] == "true")
        model.revealHeld = true
        #expect(model.isRevealing)
        #expect(model.debugState["revealing"] == "true")
        model.revealHeld = false
        model.revealPressed = true
        #expect(model.isRevealing, "プレビューのボタンを押している間も表示")
        model.open()
        #expect(!model.isRevealing)
        // 表示のキーは操作としては何もしない（押している間だけ効く）
        model.perform(.reveal)
        #expect(model.selectedIndex == 0)
    }

    @Test("⌘O: 秘密の URL は伏せ字から URL を作らず、コピー元のページだけを開く")
    func openSourceOfSecretURL() {
        var opened: [URL] = []
        let model = HistoryPanelModel(actions: history)
        model.effects.openURL = { opened.append($0) }
        model.open()
        model.select(4)
        model.openSource()
        #expect(opened.map(\.absoluteString) == ["https://dashboard.example.com/keys"])
        // コピー元のページのない秘密の URL は開かず、パネルを揺らす
        let link = ClipItem(
            id: UUID(), contentHash: "x", kind: .url, copyMethod: .other, source: nil, sourceURL: nil,
            createdAt: SampleHistory.now, lastUsedAt: SampleHistory.now, copyCount: 1, isPinned: false,
            flags: [.secretLikely, .secretKnownFormat], previewText: "https://example.com/reset?token=••••••••",
            totalBytes: 10, pasteboardItemCount: 1)
        let linkHistory = FakeHistory(items: [link])  // モデルは本体を弱参照で持つので、ここで保持する
        let single = HistoryPanelModel(actions: linkHistory)
        single.effects.openURL = { opened.append($0) }
        single.open()
        let shakes = single.shakeCount
        #expect(single.selected?.id == link.id)
        single.openSource()
        #expect(opened.count == 1)
        #expect(single.shakeCount == shakes + 1)
    }

    @Test("検索: 中身では引けず、見えている接頭辞と「秘密」（ひらがな・ローマ字）で引ける")
    func search() {
        let model = HistoryPanelModel(actions: history)
        model.open()
        let hidden = String(realText(secretKey).dropFirst(8).prefix(10))
        model.query = hidden
        #expect(!model.items.contains { $0.id == secretKey.id })
        for query in ["sk-test", "秘密", "himitsu", "ひみつ"] {
            model.query = query
            #expect(model.items.contains { $0.id == secretKey.id }, "\(query) で引けない")
        }
    }

    @Test("候補窓の行: 伏せ字の 1 行目・右は「秘密」。表示中は本当の 1 行目")
    func candidateRow() {
        let title = CandidateRowText.title(secretKey, fileName: "本当のファイル名")
        #expect(title.body == secretKey.previewText)
        #expect(title.mono)
        #expect(CandidateRowText.detail(secretKey) == "秘密")
        let model = CandidateViewModel(keymap: .default)
        model.update(
            CandidateViewState(
                sessionID: 1, items: history.items, selectedIndex: 4, order: .terminal, note: .deferredApp,
                target: nil, revealed: true))
        #expect(model.revealed)
        #expect(model.showsSecretNote)
        // 秘密の注記は 2 行ぶん（仮に貼らない理由の注記より優先）
        #expect(
            model.windowSize.height
                == CandidateLayout.windowHeight(
                    rowCount: history.items.count, noteHeight: CandidateLayout.secretNoteHeight))
    }

    @Test("秘密のカードもパネルの幅に収まる（長い 1 行・表示中・ライト・ダーク）")
    func cardWidth() {
        let width = HistoryPanelView.cardWidth
        let loader = ClipContentLoader(actions: history)
        for item in [secretKey, secretExport] {
            for revealing in [false, true] {
                for dark in [false, true] {
                    let card = CardView(
                        item: item, index: 4, isSelected: true, query: .empty, now: SampleHistory.now, quickHeld: false,
                        quickCombo: Keymap.default.primary(.quickPaste), loader: loader, revealing: revealing
                    )
                    .environment(\.palette, dark ? .dark : .light)
                    let size = NSHostingController(rootView: card).sizeThatFits(
                        in: CGSize(width: width, height: 10_000))
                    #expect(size.width <= width + 0.5)
                }
            }
        }
    }
}

/// 設定画面: 押している間だけ効くキー（隠した内容の表示）の記録と、秘密を消すまでの時間の行
@MainActor
@Suite("設定画面と秘密")
struct SecretSettingsTests {
    let dir = SettingsTempDirectory()
    let controller: SettingsController
    let model: SettingsModel

    init() {
        controller = SettingsController(file: SettingsFile(directory: dir.url))
        model = SettingsModel(
            controller: controller,
            environment: SettingsEnvironment(appName: { _ in nil }, hotKeyRegistered: { _ in true }))
        model.open()
    }

    @Test("表示のキーは、記録中に修飾キーを 1 つ押すとそのキーになる。文字のキーでは決まらない")
    func recordHold() {
        let id = SettingID.keys(.reveal)
        model.startRecording(id)
        #expect(model.recording)
        model.record(KeyStroke(keyCode: 9, modifiers: .command))  // ⌘V
        #expect(model.recording, "文字のキーでは決まらない")
        #expect(model.message?.contains("修飾キー") == true)
        model.recordModifier([.command, .shift])
        #expect(model.recording, "修飾キー 2 つでは決まらない")
        model.recordModifier(.command)
        #expect(!model.recording)
        #expect(controller.settings.keymap.combos(for: .reveal) == [KeyCombo(.hold, .command)])
        #expect(model.message == "「隠した内容を表示（押している間）」を ⌘ にしました。")
        // 記録していないときの修飾キーは何もしない
        model.recordModifier(.option)
        #expect(controller.settings.keymap.combos(for: .reveal) == [KeyCombo(.hold, .command)])
    }

    @Test("ほかの操作の記録中に修飾キーだけを押しても決まらない")
    func otherActionIgnoresModifier() {
        model.startRecording(SettingID.keys(.paste))
        model.recordModifier(.option)
        #expect(model.recording)
        #expect(controller.settings.keymap.combos(for: .paste) == KeyAction.paste.defaultCombos)
        model.cancelRecording()
    }

    @Test("「秘密を自動で消すまで」の行が「履歴」のまとまりにあり、分で出る")
    func retentionRow() {
        #expect(model.rowIDs.contains(SettingID.secretAutoDelete))
        #expect(model.sections.first { $0.title == "履歴" }?.itemIDs.contains(SettingID.secretAutoDelete) == true)
        #expect(model.valueText(SettingID.secretAutoDelete) == "10 分")
    }
}
