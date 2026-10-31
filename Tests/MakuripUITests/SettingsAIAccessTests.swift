import Foundation
import MakuripCore
import Testing

@testable import MakuripUI

/// 設定画面の「AI の口」の行（#6）。オンにできるのはこの行だけ
@MainActor
@Suite("設定画面の AI の口")
struct SettingsAIAccessTests {
    final class Fake {
        var enabled = false
        var writes: [Bool] = []
        var copied = 0
        var failWrites = false
        var activity: [AIActivityEntry] = []
    }

    let dir = SettingsTempDirectory()
    let fake = Fake()
    let model: SettingsModel

    init() {
        let fake = fake
        model = SettingsModel(
            controller: SettingsController(file: SettingsFile(directory: dir.url)),
            environment: SettingsEnvironment(
                aiAccess: AIAccessEnvironment(
                    isEnabled: { fake.enabled },
                    setEnabled: { value in
                        guard !fake.failWrites else { return false }
                        fake.writes.append(value)
                        fake.enabled = value
                        return true
                    },
                    recentActivity: { limit in Array(fake.activity.prefix(limit)) },
                    registerCommand: { "claude mcp add --scope user makurip -- /Applications/Makurip.app/x --mcp" },
                    copyRegisterCommand: { fake.copied += 1 })))
        model.open()
    }

    func press(_ code: UInt16, _ modifiers: HotKey.Modifiers = []) {
        _ = model.handle(KeyStroke(keyCode: code, modifiers: modifiers))
    }

    @Test("動きのまとまりの後・キーの前に「AI の口」の行がある（設定の項目ではない）")
    func placement() {
        let titles = model.sections.map(\.title)
        let index = titles.firstIndex(of: "AI の口")
        #expect(index == titles.firstIndex(of: "詳細").map { $0 + 1 })
        #expect(model.rowIDs.contains(SettingsModel.aiAccessRowID))
        #expect(SettingsSchema.item(SettingsModel.aiAccessRowID) == nil)
    }

    @Test("↩・←→ で切り替え、⌫ でオフ（初期値）。すべて初期値に戻すとオフ")
    func toggle() {
        model.select(SettingsModel.aiAccessRowID)
        press(KeyCodes.returnKey)
        #expect(fake.enabled)
        #expect(model.aiAccessEnabled)
        #expect(model.message?.contains("オンにしました") == true)
        press(KeyCodes.rightArrow)
        #expect(!fake.enabled)
        press(KeyCodes.leftArrow)
        #expect(fake.enabled)
        press(KeyCodes.delete)
        #expect(!fake.enabled)
        model.setAIAccess(true)
        model.resetAll()
        #expect(!fake.enabled)
        #expect(fake.writes == [true, false, true, false, true, false])
    }

    @Test("書けなかったら理由を出し、表示はそのまま")
    func writeFailure() {
        fake.failWrites = true
        model.setAIAccess(true)
        #expect(!model.aiAccessEnabled)
        #expect(model.message?.contains("切り替えられませんでした") == true)
    }

    @Test("ほかから変わったら（AI の操作の記録・CLI の disable）描き直しで読み直す")
    func refresh() {
        fake.enabled = true
        fake.activity = [
            AIActivityEntry(
                at: Date(timeIntervalSince1970: 1_800_000_000), channel: .mcp, client: "claude-code",
                tool: "add_to_history", outcome: .ok, summary: "コマンドを履歴に追加しました。")
        ]
        #expect(!model.aiAccessEnabled)
        model.environmentDidChange()
        #expect(model.aiAccessEnabled)
        #expect(model.aiActivity.count == 1)
        #expect(SettingsAIAccessRow.line(model.aiActivity[0]).contains("claude-code・add_to_history"))
        model.copyMCPRegisterCommand()
        #expect(fake.copied == 1)
    }

    @Test("AI の口の口がないときは行を出さない")
    func hiddenWithoutEnvironment() {
        let plain = SettingsModel(controller: SettingsController(file: SettingsFile(directory: dir.url)))
        #expect(!plain.rowIDs.contains(SettingsModel.aiAccessRowID))
    }
}
