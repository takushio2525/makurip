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
    func everyCommandOnce() throws {
        var state = base
        state.accessibilityTrusted = false
        state.update = UpdateStatus(
            currentVersion: "0.1.0",
            availability: .available(
                try #require(try ReleaseFeed.latest(in: FeedFixture.data([FeedFixture.release("0.2.0")])))))
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

/// メニューのアップデートの知らせ（#43）
@Suite("メニューバーのメニュー: アップデート")
struct StatusMenuUpdateTests {
    static func release(_ version: String) throws -> UpdateRelease {
        try #require(try ReleaseFeed.latest(in: FeedFixture.data([FeedFixture.release(version)])))
    }

    func state(_ update: UpdateStatus?) -> StatusMenuModel.State {
        StatusMenuModel.State(
            appName: "Makurip", paused: false, accessibilityTrusted: true, itemCount: 3, isolated: false, update: update
        )
    }

    func items(_ update: UpdateStatus?) -> [StatusMenuModel.Item] {
        StatusMenuModel.entries(state(update)).compactMap {
            if case .item(let item) = $0 { item } else { nil }
        }
    }

    @Test("新しい版があれば、先頭に知らせと「アップデートして再起動」「この版は知らせない」を出す")
    func announcesAtTop() throws {
        let update = UpdateStatus(currentVersion: "0.1.0", availability: .available(try Self.release("0.2.0")))
        let entries = StatusMenuModel.entries(state(update))
        #expect(entries.first == .info("新しい版 v0.2.0 があります（今は v0.1.0）"))
        #expect(Array(items(update).prefix(2).map(\.command)) == [.installUpdate, .skipUpdate])
        #expect(entries[3] == .separator)
    }

    @Test("最新・「この版は知らせない」にした版では、先頭に何も出さない")
    func quietWhenNothingToAnnounce() throws {
        for availability in [UpdateAvailability.upToDate, .skipped(try Self.release("0.2.0"))] {
            let update = UpdateStatus(currentVersion: "0.1.0", availability: availability)
            #expect(items(update).first?.command == .openList)
            #expect(!items(update).contains { $0.command == .installUpdate || $0.command == .skipUpdate })
        }
    }

    @Test("「アップデートを確認…」は設定の次。確かめている間・入れ替えている間は押せない")
    func checkItem() throws {
        let idle = items(UpdateStatus(currentVersion: "0.1.0"))
        let index = try #require(idle.firstIndex { $0.command == .checkForUpdates })
        #expect(idle[index - 1].command == .openSettings)
        #expect(idle[index].title == "アップデートを確認…")
        #expect(idle[index].enabled)

        let checking = items(UpdateStatus(currentVersion: "0.1.0", phase: .checking))
        #expect(checking.first { $0.command == .checkForUpdates }?.title == "アップデートを確かめています…")
        #expect(checking.first { $0.command == .checkForUpdates }?.enabled == false)

        let installing = UpdateStatus(
            currentVersion: "0.1.0", phase: .installing(.download), availability: .available(try Self.release("0.2.0")))
        #expect(StatusMenuModel.entries(state(installing)).first == .info("アップデートしています…（ダウンロード）"))
        #expect(!items(installing).contains { $0.command == .installUpdate || $0.command == .skipUpdate })
        #expect(items(installing).first { $0.command == .checkForUpdates }?.enabled == false)
    }

    @Test("失敗したら先頭に短く出し、もう一度入れ替える・知らせないを選べる")
    func failed() throws {
        let update = UpdateStatus(
            currentVersion: "0.1.0", phase: .failed(UpdateFailure.checksumMismatch.message),
            availability: .available(try Self.release("0.2.0")))
        let entries = StatusMenuModel.entries(state(update))
        #expect(entries.first == .info("アップデートできませんでした（今の版のままです。理由は設定画面）"))
        #expect(Array(items(update).prefix(2).map(\.command)) == [.installUpdate, .skipUpdate])
    }

    @Test("置き換えられない場所では「アップデートして再起動」を出さず、理由の場所を示す")
    func blocked() throws {
        let update = UpdateStatus(
            currentVersion: "0.1.0", availability: .available(try Self.release("0.2.0")),
            blockedReason: UpdateFailure.translocated.message)
        #expect(!items(update).contains { $0.command == .installUpdate })
        #expect(StatusMenuModel.entries(state(update)).contains(.info("この場所からは入れ替えられません（理由は設定画面）")))
    }

    @Test("アップデートの状態を渡さなければ（古い呼び方）、アップデートの項目は出ない")
    func absent() {
        #expect(!items(nil).contains { $0.command == .checkForUpdates })
    }
}
