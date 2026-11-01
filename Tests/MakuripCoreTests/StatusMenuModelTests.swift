import Testing

@testable import MakuripCore

/// メニューバーのアイコンを押して開くメニュー（#35）。すべての画面と主な操作へ行けること
@Suite("メニューバーのメニュー")
struct StatusMenuModelTests {
    let base = StatusMenuModel.State(
        appName: "Makurip", paused: false, accessibilityTrusted: true, itemCount: 12, isolated: false)

    func items(_ state: StatusMenuModel.State) -> [StatusMenuModel.Item] {
        StatusMenuModel.entries(state).compactMap {
            if case .item(let item) = $0 { item } else { nil }
        }
    }

    func infos(_ state: StatusMenuModel.State) -> [String] {
        StatusMenuModel.entries(state).compactMap {
            if case .info(let text) = $0 { text } else { nil }
        }
    }

    @Test("一覧・定型文の一覧・定型文の窓・設定の 4 つの画面へ、この順で行ける")
    func reachesEveryScreen() {
        let commands = items(base).map(\.command)
        #expect(Array(commands.prefix(4)) == [.openList, .openSnippetList, .editSnippets, .openSettings])
    }

    @Test("許可がないときは、すべての操作が 1 回ずつ並ぶ（許可があれば許可の項目だけ出ない）")
    func everyCommandOnce() {
        var state = base
        state.accessibilityTrusted = false
        let commands = items(state).map(\.command)
        #expect(
            commands.sorted { $0.rawValue < $1.rawValue }
                == StatusMenuModel.Command.allCases.sorted { $0.rawValue < $1.rawValue })
        #expect(!items(base).map(\.command).contains(.requestAccessibility))
    }

    @Test("画面を開く項目にはキーマップの操作を添える（表示はいまの割り当てから引く）")
    func keysFromKeymap() {
        let keys = Dictionary(uniqueKeysWithValues: items(base).map { ($0.command, $0.key) })
        #expect(keys[.openList] == .openList)
        #expect(keys[.openSnippetList] == .snippets)
        #expect(keys[.editSnippets] == .editSnippet)
        #expect(keys[.openSettings] == .settings)
        #expect(keys[.togglePause] == .some(nil))
        #expect(keys[.quit] == .some(nil))
    }

    @Test("一時停止中は「記録を再開」と状態の行に出す。検証用フォルダも状態の行に出す")
    func pausedAndIsolated() {
        #expect(items(base).first { $0.command == .togglePause }?.title == "記録を一時停止")
        #expect(infos(base) == ["履歴 12 件"])
        var state = base
        state.paused = true
        state.isolated = true
        #expect(items(state).first { $0.command == .togglePause }?.title == "記録を再開")
        #expect(infos(state) == ["履歴 12 件・一時停止中・検証用フォルダ"])
    }

    @Test("終了は最後。区切りが続いたり端に来たりしない")
    func layout() {
        let entries = StatusMenuModel.entries(base)
        #expect(entries.last == .item(.init(command: .quit, title: "Makurip を終了", key: nil)))
        #expect(entries.first != .separator)
        for (a, b) in zip(entries, entries.dropFirst()) {
            #expect(!(a == .separator && b == .separator))
        }
    }
}
