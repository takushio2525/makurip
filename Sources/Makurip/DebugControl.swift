import AppKit
import ApplicationServices
import MakuripCore

/// E2E 用の遠隔操作（`--debug-control`）。**`--data-dir` で隔離したときだけ**有効にする（AppController が守る）。
///
/// 分散通知 `com.takushio2525.makurip.debug.<命令>` を、object = データフォルダのパスで受け取る
/// （別のデータフォルダで動く別インスタンスには届かない）。状態は `<データフォルダ>/debug-status.json` に書く。
/// 状態に中身（平文・データ）は入れない。
@MainActor
final class DebugControl {
    static let prefix = "com.takushio2525.makurip.debug."

    enum Command: String, CaseIterable {
        /// 一覧を開く / 閉じる（メニューの「履歴の一覧を開く」と同じ）
        case toggleHistory
        /// ⌃⌘V を押したときと同じ（動きは hotkeyMode。既定は候補窓）
        case pressOpenKey
        /// ⌃⌥⌘V を押したときと同じ
        case pressOpenListKey
        /// ⌘C を見たときと同じ信号を入れる（コピー方法の判定の配線を確かめる用）
        case simulateCopyShortcut
        /// 貼り付けの宛先を pid で固定する（userInfo["pid"]）
        case setPasteTarget
        /// 記録の一時停止・再開（メニューの「記録を一時停止」と同じ）
        case pause
        case resume
        /// アップデートを確かめる（メニューの「アップデートを確認…」と同じ。結果の窓は出さず、状態に書く。#43）
        case checkForUpdates
        /// 見つけた新しい版に入れ替えて起動し直す（メニューの「アップデートして再起動」と同じ。失敗の窓は出さない）
        case installUpdate
        /// 見つけた新しい版を知らせないようにする（メニューの「この版は知らせない」と同じ）
        case skipUpdate
        /// 定型文を貼る（userInfo["index"] は 1 からの番号、["mode"] は normal・plainText・copyOnly。一覧の Enter と同じ）
        case pasteSnippet
        /// 履歴を消去する（メニューの「履歴を消去…」の確かめの後と同じ。ピン留めと定型文は残る）
        case clearHistory
        /// AI の口をオン・オフにする（設定画面の切り替えと同じ。隔離したときだけ効くので、本物の履歴の口は開けられない）
        case enableAIAccess
        case disableAIAccess
        /// 設定画面の「登録コマンドをコピー」と同じ（書き戻しが新しい履歴にならないかを E2E で確かめる用）
        case copyMCPRegisterCommand
        /// 一覧を定型文の表示で開く（メニューの「定型文の一覧を開く」と同じ）
        case openSnippetList
        /// 一覧のカードを左クリックする（userInfo["index"] は上から 1 始まり。窓の中で作った出来事を窓へ送る。#38）
        case clickCard
        /// 一覧のカードを押したまま、カードの外へ出て離す（貼らないはず）
        case clickCardReleaseOutside
        /// 一覧のカードを右クリックしてメニューを出し、userInfo["hold"] 秒後（既定 1）に userInfo["action"] の項目
        /// （キーマップの操作 ID。paste・copyOnly など）を選ぶ。action が無ければ何も選ばずに閉じる。
        /// メニューを開いている間は分散通知が届かないので、選ぶ前に状態を 1 回書く（メニューの中でも回るタイマー）
        case rightClickCard
        /// 一覧のカードの上で下へスクロールする（貼らないはず）
        case scrollCards
        /// 一覧がキーの焦点を取らない / 取る（既定は取る）。取らないと、出しても使っている人の打鍵を横取りせず、外の操作でも閉じない
        case panelKeyFocusOff
        case panelKeyFocusOn
        /// 状態を書く
        case writeStatus
        case quit
    }

    private weak var controller: AppController?
    private var observers: [NSObjectProtocol] = []
    private let statusURL: URL

    init(controller: AppController) {
        self.controller = controller
        statusURL = controller.dataDirectory.appendingPathComponent("debug-status.json")
        let center = DistributedNotificationCenter.default()
        let object = controller.dataDirectory.path
        for command in Command.allCases {
            let observer = center.addObserver(
                forName: Notification.Name(Self.prefix + command.rawValue), object: object, queue: .main
            ) { [weak self] notification in
                let info = notification.userInfo ?? [:]
                let pid =
                    (info["pid"] as? NSNumber)?.int32Value ?? (info["pid"] as? String).flatMap { Int32($0) }
                let index = (info["index"] as? NSNumber)?.intValue ?? (info["index"] as? String).flatMap { Int($0) }
                let mode = (info["mode"] as? String).flatMap(PasteMode.init(rawValue:))
                let action = (info["action"] as? String).flatMap(KeyAction.init(rawValue:))
                let hold = (info["hold"] as? NSNumber)?.doubleValue ?? (info["hold"] as? String).flatMap { Double($0) }
                MainActor.assumeIsolated {
                    self?.handle(command, pid: pid, index: index, mode: mode, action: action, hold: hold)
                }
            }
            observers.append(observer)
        }
        writeStatus()
        Log.app.info("検証用の遠隔操作を有効にした")
    }

    private func handle(
        _ command: Command, pid: Int32?, index: Int? = nil, mode: PasteMode? = nil, action: KeyAction? = nil,
        hold: Double? = nil
    ) {
        guard let controller else { return }
        switch command {
        case .toggleHistory:
            controller.toggleHistory()
        case .pressOpenKey:
            controller.hotKeyPressed(.open)
        case .pressOpenListKey:
            controller.hotKeyPressed(.openList)
        case .simulateCopyShortcut:
            let front = NSWorkspace.shared.frontmostApplication
            controller.monitor?.noteCopyShortcut(
                CopyShortcutSignal(
                    at: Date(),
                    frontmostApp: front.map { SourceApp(bundleID: $0.bundleIdentifier, name: $0.localizedName) }))
        case .setPasteTarget:
            controller.pasteTargetOverride = pid
        case .pause:
            controller.setPaused(true)
        case .resume:
            controller.setPaused(false)
        case .checkForUpdates:
            controller.updates?.check(presentResult: false)
        case .installUpdate:
            controller.updates?.install(presentFailure: false)
        case .skipUpdate:
            controller.updates?.skip()
        case .pasteSnippet:
            let list = controller.snippets()
            if let index, list.indices.contains(index - 1) {
                controller.pasteSnippet(id: list[index - 1].id, mode: mode ?? .normal)
            }
        case .clearHistory:
            controller.clearHistory()
        case .enableAIAccess:
            controller.setAIAccess(true)
        case .disableAIAccess:
            controller.setAIAccess(false)
        case .copyMCPRegisterCommand:
            controller.copyMCPRegisterCommand()
        case .openSnippetList:
            controller.openSnippetList()
        case .clickCard:
            controller.history?.debugPerform(.click(row: index ?? 1, releaseInside: true))
        case .clickCardReleaseOutside:
            controller.history?.debugPerform(.click(row: index ?? 1, releaseInside: false))
        case .rightClickCard:
            let hold = min(max(hold ?? 1, 0.5), 5)
            controller.history?.debugPerform(.rightClick(row: index ?? 1, choose: action, hold: hold))
            // メニューを開いている間（選ぶ前）の状態を書く
            let timer = Timer(timeInterval: hold * 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.writeStatus() }
            }
            RunLoop.main.add(timer, forMode: .common)
        case .scrollCards:
            controller.history?.debugPerform(.scroll(row: index ?? 1))
        case .panelKeyFocusOff:
            controller.history?.debugPerform(.takesKeyFocus(false))
        case .panelKeyFocusOn:
            controller.history?.debugPerform(.takesKeyFocus(true))
        case .writeStatus:
            break
        case .quit:
            writeStatus()
            NSApp.terminate(nil)
            return
        }
        // 一覧の表示などが落ち着いてから書く
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.writeStatus() }
        }
    }

    /// 設定の値（秘密は入らない）と、ファイルから読み直した回数・読めなかった項目の数
    private static func settingsSummary(_ controller: AppController) -> [String: Any] {
        guard let settings = controller.settings else { return [:] }
        var summary: [String: Any] = [
            "reloadCount": settings.reloadCount, "issueCount": settings.issues.count, "watching": settings.isWatching,
        ]
        for id in [
            SettingID.hotKeyMode, SettingID.candidateOrder, SettingID.maxItems, SettingID.maxTotalMegabytes,
            SettingID.keys(.openHistory), SettingID.keys(.openList), SettingID.excludedApps,
            SettingID.secretAutoDelete,
        ] {
            summary[id] = SettingsSchema.value(id, in: settings.settings)?.compactText
        }
        return summary
    }

    /// 定型文の件数・読み直した回数・読めなかった項目の数と、直近に貼った定型文の長さ（中身は出さない。
    /// 秘密の形の値を含んだときは長さとカーソルの位置も "hidden"。#29 L3）
    private static func snippetSummary(_ controller: AppController) -> [String: Any] {
        var summary: [String: Any] = [
            "count": controller.snippets().count,
            "reloadCount": controller.snippetStore?.reloadCount ?? 0,
            "issueCount": controller.snippetStore?.issues.count ?? 0,
            "watching": controller.snippetStore?.isWatching ?? false,
            "editorVisible": controller.isSnippetEditorVisible,
            "dateFormat": controller.snippetDateFormat().rawValue,
        ]
        if let last = controller.lastSnippetPaste, last.concealed {
            summary["lastPasteLength"] = "hidden"
            summary["lastCursorOffsetFromEnd"] = "hidden"
        } else if let last = controller.lastSnippetPaste {
            summary["lastPasteLength"] = last.length
            summary["lastCursorOffsetFromEnd"] = last.cursorOffsetFromEnd ?? NSNull()
        }
        return summary
    }

    /// AI の口（オンか・外から履歴が変わったと知らされた回数・記録の件数と直近の道具と結果。中身は出さない）
    private static func aiSummary(_ controller: AppController) -> [String: Any] {
        let recent = controller.aiActivity.recent(limit: AIActivityLog.maxEntries)
        return [
            "enabled": controller.isAIAccessEnabled,
            "externalHistoryChanges": controller.externalHistoryChanges,
            "activityCount": recent.count,
            "lastTool": recent.first?.tool ?? "",
            "lastOutcome": recent.first?.outcome.rawValue ?? "",
        ]
    }

    func writeStatus() {
        guard let controller else { return }
        var status: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "accessibilityTrusted": AXIsProcessTrusted(),
            "keyMonitorActive": controller.detector?.isActive ?? false,
            "hotKeys": controller.hotKeys.registered.values.map(\.displayString).sorted(),
            "pasteboard": controller.options.pasteboardName == nil ? "general" : "named",
            "paused": controller.isPaused,
            "itemCount": controller.itemCount,
            "historyVisible": controller.history?.isVisible ?? false,
            "historyUI": controller.history?.debugState ?? [:],
            "candidate": controller.candidate?.debugState ?? [:],
            "pasteTargetOverride": controller.pasteTargetOverride.map { Int($0) } ?? NSNull(),
            "lastPasteOutcome": controller.lastPasteOutcome ?? NSNull(),
            "lastHotKeyRoute": controller.lastHotKeyRoute ?? NSNull(),
            "openKeyRoute": controller.previewRoute(.open) ?? NSNull(),
            "storeLimits": [
                "maxItems": controller.store?.limits.maxItems ?? 0,
                "maxTotalBytes": controller.store?.limits.maxTotalBytes ?? 0,
            ],
            "candidateHotKeyMode": controller.candidate?.settings.hotKeyMode.rawValue ?? "",
            "settings": Self.settingsSummary(controller),
            "settingsVisible": controller.isSettingsVisible,
            "statusItem": controller.statusItemState,
            "snippets": Self.snippetSummary(controller),
            "secrets": controller.secretStatus,
            "ai": Self.aiSummary(controller),
            "update": controller.updates?.debugState ?? [:],
        ]
        status["writtenAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: statusURL, options: .atomic)
        }
    }
}
