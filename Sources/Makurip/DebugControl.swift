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
                let pid =
                    (notification.userInfo?["pid"] as? NSNumber)?.int32Value
                    ?? (notification.userInfo?["pid"] as? String).flatMap { Int32($0) }
                MainActor.assumeIsolated { self?.handle(command, pid: pid) }
            }
            observers.append(observer)
        }
        writeStatus()
        Log.app.info("検証用の遠隔操作を有効にした")
    }

    private func handle(_ command: Command, pid: Int32?) {
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
        ] {
            summary[id] = SettingsSchema.value(id, in: settings.settings)?.compactText
        }
        return summary
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
            "storeLimits": [
                "maxItems": controller.store?.limits.maxItems ?? 0,
                "maxTotalBytes": controller.store?.limits.maxTotalBytes ?? 0,
            ],
            "candidateHotKeyMode": controller.candidate?.settings.hotKeyMode.rawValue ?? "",
            "settings": Self.settingsSummary(controller),
            "settingsVisible": controller.isSettingsVisible,
        ]
        status["writtenAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: statusURL, options: .atomic)
        }
    }
}
