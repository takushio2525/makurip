import AppKit
import Foundation
import Testing

@testable import MakuripCore

/// 反映先の偽物。上限だけは本物のストアに当てる（下げたらその場で消えるのを確かめる）
@MainActor
final class FakeSettingsTarget: SettingsApplying {
    var store: ClipStore?
    var calls: [String] = []
    var limits: Limits?
    var excluded: Set<String>?
    var globalKeys: (open: HotKey?, openList: HotKey?)?
    var keymap: Keymap?
    var candidate: CandidateSettings?
    var launchAtLogin: Bool?
    var secretRetention: TimeInterval?

    func applyLimits(_ limits: Limits) {
        calls.append("limits")
        self.limits = limits
        _ = try? store?.setLimits(limits)
    }
    func applyExcludedApps(_ bundleIDs: Set<String>) {
        calls.append("excluded")
        excluded = bundleIDs
    }
    func applyGlobalKeys(open: HotKey?, openList: HotKey?) {
        calls.append("globalKeys")
        globalKeys = (open, openList)
    }
    func applyKeymap(_ keymap: Keymap) {
        calls.append("keymap")
        self.keymap = keymap
    }
    func applyCandidateSettings(_ settings: CandidateSettings) {
        calls.append("candidate")
        candidate = settings
    }
    func applyLaunchAtLogin(_ enabled: Bool) {
        calls.append("launchAtLogin")
        launchAtLogin = enabled
    }
    func applySecretRetention(_ retention: TimeInterval) {
        calls.append("secretRetention")
        secretRetention = retention
    }
}

/// 条件がそろうまで待つ（メインのキューを回しながら。ファイルの監視は main で届く）
@MainActor
func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
@Suite("設定の反映", .serialized)
struct SettingsLiveTests {
    func cli(_ dir: TemporaryDirectory) -> SettingsCLI {
        SettingsCLI(file: SettingsFile(directory: dir.url))
    }

    @Test("画面から変えると、ファイルに書いて知らせる（前と後の値）")
    func setFromWindow() throws {
        let dir = TemporaryDirectory()
        let controller = SettingsController(file: SettingsFile(directory: dir.url))
        var seen: [(AppSettings, AppSettings)] = []
        controller.observe { seen.append(($0, $1)) }
        try controller.set(SettingID.hotKeyMode, .string("list"))
        #expect(seen.count == 1)
        #expect(seen.first?.0.hotKeyMode == .list)
        #expect(seen.first?.1.hotKeyMode == .candidate)
        #expect(SettingsFile(directory: dir.url).load().settings.hotKeyMode == .list)

        #expect(throws: SettingsError.self) { try controller.set(SettingID.maxItems, .int(3)) }
        #expect(seen.count == 1)
        let moved = try controller.set(SettingID.keys(.cycleMethod), .string("⌘E"), keyConflicts: .takeOver)
        #expect(moved == [.chooseApp])
        try controller.reset(SettingID.hotKeyMode)
        #expect(controller.settings.hotKeyMode == .candidate)
        try controller.resetAll()
        #expect(controller.settings == .default)
    }

    @Test("CLI（別のプロセスと同じ書き方）で書くと、監視が読み直して知らせる")
    func reloadsWhenCLIWrites() async throws {
        let dir = TemporaryDirectory()
        let controller = SettingsController(file: SettingsFile(directory: dir.url))
        controller.reloadDelay = 0.02
        var latest: AppSettings?
        controller.observe { new, _ in latest = new }
        controller.startWatching()
        defer { controller.stopWatching() }

        // まだファイルがない状態から作られる
        #expect(cli(dir).run(["set", "hotkeyMode", "paste"]).exitCode == 0)
        #expect(await waitUntil { latest?.hotKeyMode == .pasteOnly })
        // 置き換えで書かれたあとの変化も拾う（ファイルの監視を付け直している）
        #expect(cli(dir).run(["set", "maxItems", "200"]).exitCode == 0)
        #expect(await waitUntil { latest?.maxItems == 200 })
        #expect(controller.reloadCount == 2)
    }

    @Test("その場で書き換えたとき・手で壊したとき・同じ中身で書き直したとき")
    func inPlaceAndBrokenWrites() async throws {
        let dir = TemporaryDirectory()
        let file = SettingsFile(directory: dir.url)
        try file.save(.default)
        let controller = SettingsController(file: file)
        controller.reloadDelay = 0.02
        var count = 0
        controller.observe { _, _ in count += 1 }
        controller.startWatching()
        defer { controller.stopWatching() }

        // その場で書き換える（置き換えずに、同じファイルを開いて書く）
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"settings": {"candOrder": "ime"}}"#.utf8))
        try handle.close()
        #expect(await waitUntil { controller.settings.candidateOrder == .ime })
        #expect(count == 1)

        // 手で壊す → 既定で動き、理由を持つ
        try Data("{ broken".utf8).write(to: file.url, options: .atomic)
        #expect(await waitUntil { controller.settings == .default })
        #expect(controller.issues.first?.id == SettingsFile.fileName)
        #expect(count == 2)

        // 画面から変えると、壊れたファイルを退避してから書く
        try controller.set(SettingID.maxItems, .int(300))
        #expect(
            FileManager.default.fileExists(atPath: dir.url.appendingPathComponent(SettingsFile.brokenFileName).path))
        #expect(controller.issues.isEmpty)
        #expect(count == 3)

        // 同じ中身を書き直しても知らせない
        let data = try Data(contentsOf: file.url)
        try data.write(to: file.url, options: .atomic)
        try await Task.sleep(for: .milliseconds(200))
        #expect(count == 3)
    }

    @Test("起動時は全部を当てる（ログイン時の起動は除く）。変わったら変わった部分だけ")
    func applierCallsOnlyChangedParts() {
        let target = FakeSettingsTarget()
        SettingsApplier.apply(.default, previous: nil, to: target)
        #expect(target.calls == ["limits", "excluded", "globalKeys", "keymap", "candidate", "secretRetention"])
        #expect(target.globalKeys?.open == .defaultOpenHistory)
        #expect(target.globalKeys?.openList == .defaultOpenList)

        func change(_ edit: (inout AppSettings) -> Void) -> [String] {
            target.calls = []
            var new = AppSettings.default
            edit(&new)
            SettingsApplier.apply(new, previous: .default, to: target)
            return target.calls
        }
        #expect(change { $0.hotKeyMode = .pasteOnly } == ["candidate"])
        #expect(change { $0.candidateOrder = .ime } == ["candidate"])
        #expect(change { $0.maxItems = 200 } == ["limits"])
        #expect(change { $0.excludedApps = ["com.example.a"] } == ["excluded"])
        #expect(change { $0.excludedApps = [] } == [])
        #expect(change { $0.launchAtLogin = true } == ["launchAtLogin"])
        #expect(change { $0.secretAutoDeleteMinutes = 60 } == ["secretRetention"])
        #expect(target.secretRetention == 3600)
        #expect(change { $0.keymap.set([KeyCombo(.code(9), .option)], for: .openHistory) } == ["globalKeys", "keymap"])
        #expect(change { $0.keymap.set([KeyCombo(.code(38), .command)], for: .cycleMethod) } == ["keymap"])
        #expect(change { $0.keymap.set([], for: .openList) } == ["globalKeys", "keymap"])
        #expect(target.globalKeys?.openList == nil)
    }

    @Test("CLI で変えると、動いている側に上限・呼び出しキー・キーマップ・候補窓の動きが届く（上限を下げたらその場で消す）")
    func endToEndThroughFile() async throws {
        let dir = TemporaryDirectory()
        // ストアに入れる重い処理はメインの外で行う（メインを塞ぐと、ペーストボード監視の時間に敏感なテストが落ちる）
        let url = dir.url
        let store = try await Task.detached {
            let store = try ClipStore(directory: url)
            for index in 0..<15 { try store.save(makeClip(Fixtures.text("item \(index)"), at: TimeInterval(index))) }
            try store.setPinned(true, id: try #require(store.items().last).id)  // いちばん古いものをピン留め
            return store
        }.value

        let controller = SettingsController(file: SettingsFile(directory: dir.url))
        controller.reloadDelay = 0.02
        let target = FakeSettingsTarget()
        target.store = store
        SettingsApplier.apply(controller.settings, previous: nil, to: target)
        controller.observe { new, old in SettingsApplier.apply(new, previous: old, to: target) }
        controller.startWatching()
        defer { controller.stopWatching() }

        #expect(cli(dir).run(["set", "maxItems", "10"]).exitCode == 0)
        #expect(await waitUntil { store.limits.maxItems == 10 })
        #expect(try store.count() == 11)  // ピン留め以外の 10 件 + ピン留め 1 件
        #expect(try store.items().contains(where: \.isPinned))

        #expect(cli(dir).run(["set", "keys.open", "⌃⌥⌘F12"]).exitCode == 0)
        #expect(await waitUntil { target.globalKeys?.open?.keyCode == 111 })
        #expect(target.keymap?.primary(.openHistory)?.displayString == "⌃⌥⌘F12")

        #expect(cli(dir).run(["set", "hotkeyMode", "paste"]).exitCode == 0)
        #expect(await waitUntil { target.candidate?.hotKeyMode == .pasteOnly })

        #expect(cli(dir).run(["set", "keys.candCommit", "↩"]).exitCode == 0)
        #expect(await waitUntil { target.keymap?.combos(for: .candidateCommit).count == 1 })
        #expect(target.keymap?.action(for: KeyStroke(keyCode: KeyCodes.tab), scope: .candidate) == nil)
    }

    @Test("候補窓の流れにキーマップを渡すと、窓のヒントにも届く")
    func coordinatorForwardsKeymap() {
        let host = FakeCandidateHost(items: [], editor: FakeEditor(""))
        let presenter = FakePresenter()
        let coordinator = CandidateCoordinator(
            host: host, presenter: presenter, tap: FakeTap(), scheduler: FakeScheduler())
        var keymap = Keymap.default
        keymap.set([KeyCombo(.code(KeyCodes.returnKey))], for: .candidateCommit)
        coordinator.keymap = keymap
        #expect(presenter.keymap == keymap)
    }
}

/// ストアだけを使うのでメインに縛らない（メインを塞がない）
@Suite("上限を下げる")
struct SettingsLimitTests {
    @Test("上限を下げると古い順（ピン留め以外）にその場で消す。上げても消さない")
    func lowerLimits() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        for index in 0..<20 { try store.save(makeClip(Fixtures.text("x\(index)"), at: TimeInterval(index))) }
        var limits = Limits.default
        limits.maxItems = 25
        #expect(try store.setLimits(limits).isEmpty)
        limits.maxItems = 12
        #expect(try store.setLimits(limits).count == 8)
        #expect(try store.count() == 12)
        #expect(try store.items().last?.previewText == "x8")  // 古い 8 件が消えた
        // 新しく保存しても上限は保たれる
        try store.save(makeClip(Fixtures.text("new"), at: 100))
        #expect(try store.count() == 12)
    }
}

@MainActor
@Suite("記録しないアプリ")
struct SettingsExcludedAppTests {
    @Test("記録しないアプリが前面にあるときは、データを読まずに捨てる（大文字・小文字は区別しない）")
    func excludedApps() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let board = PrivatePasteboard()
        var front = SourceApp(bundleID: "com.Example.Secret", name: "Secret")
        let monitor = PasteboardMonitor(
            pasteboard: board.pasteboard, store: store, limits: .default,
            environment: .init(now: { Date() }, frontmostApp: { front }, keyMonitorActive: { false }), settleDelay: 0)
        monitor.excludedApps = ["com.example.secret"]
        board.write([[(PasteboardTypes.utf8PlainText, Data("from secret app".utf8))]])
        #expect(monitor.poll() == .skipped(.excludedApp))
        #expect(try store.count() == 0)

        front = SourceApp(bundleID: "com.example.other", name: "Other")
        board.write([[(PasteboardTypes.utf8PlainText, Data("from other app".utf8))]])
        guard case .saved = monitor.poll() else {
            Issue.record("ほかのアプリのコピーが取り込まれなかった")
            return
        }
        #expect(try store.count() == 1)
    }
}
