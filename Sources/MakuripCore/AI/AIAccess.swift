import Foundation

/// AI の口（MCP・`--ai` の CLI）のオンとオフ。既定はオフ。
///
/// 値はデータフォルダの DB の `meta` 表（`aiAccess`）に置き、設定ファイル（`settings.json`）と設定のスキーマには載せない。
/// AI が設定の CLI・MCP の設定の道具・設定ファイルの書き換えでオンにできないようにするため（#4 の所見 6 と同じ考え方。
/// 自分で口を開けられない）。**オンにする `setEnabled(true, …)` を呼ぶのは、本体の設定画面の配線だけ**。
/// オフにするのはどこからでもよい（安全側。CLI の `--ai disable`）。
///
/// 限界: 同じユーザーで動くプロセスは DB を直接書き換えられる（`sqlite3` で `meta` を書くなど）。それはこの仕組みでは防げない
/// （`.agent/conventions.md` の「AI の口」）
public enum AIAccess {
    public static let metaKey = "aiAccess"
    public static let changedAtKey = "aiAccessChangedAt"
    static let onValue = "on"
    static let offValue = "off"

    /// オンか。DB がまだない（一度も起動していない）データフォルダはオフ（DB を作らずに確かめる）
    public static func isEnabled(directory: URL) -> Bool {
        let database = directory.appendingPathComponent(ClipStore.databaseFileName)
        guard FileManager.default.fileExists(atPath: database.path),
            let store = try? ClipStore(directory: directory)
        else { return false }
        return isEnabled(store: store)
    }

    public static func isEnabled(store: ClipStore) -> Bool {
        (try? store.metaValue(metaKey)) == onValue
    }

    /// 切り替える。**オンにするのは設定画面からだけ**（CLI・MCP の道具はここを true で呼ばない。`AIToolsTests` が守る）
    public static func setEnabled(_ enabled: Bool, store: ClipStore, now: Date = Date()) throws {
        try store.setMetaValue(enabled ? onValue : offValue, for: metaKey)
        try store.setMetaValue(String(now.timeIntervalSince1970), for: changedAtKey)
    }

    /// 最後に切り替えた時刻（設定画面の注記用）
    public static func changedAt(store: ClipStore) -> Date? {
        (try? store.metaValue(changedAtKey)).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
    }

    /// 設定の CLI・MCP の設定の道具で、AI の口を指していそうな ID（「そういう項目はない」ではなく、設定画面からだけと答えるため）
    public static func looksLikeGateID(_ id: String) -> Bool {
        let letters = id.lowercased().filter { $0.isLetter }
        return ["aiaccess", "ai", "mcp", "aigateway", "aienabled", "enableai", "aiport", "mcpenabled"].contains(letters)
    }

    /// オフのときに道具が返す文（AI がそのままユーザーに伝えられる形）
    public static let disabledMessage =
        "Makurip の「AI の口」がオフです。ユーザーが Makurip の設定画面（メニューバーの Makurip → 設定…）の「AI の口」でオンにする必要があります。AI・CLI・MCP からはオンにできません。ユーザーにオンにするよう頼んでください（設定の道具 settings_* はオフでも使えます）。"

    /// AI・CLI からオンにしようとしたときの文
    public static let enableRefusedMessage =
        "AI の口のオン・オフは設定画面からだけ変えられます（AI・CLI・MCP からは変えられません。AI が自分で口を開けないようにするため）。ユーザーに、Makurip の設定画面の「AI の口」でオンにするよう頼んでください。"
}

/// 動いている Makurip に「履歴が外から変わった」と知らせる分散通知（MCP・`--ai` の CLI が DB を書いたあとに送る）。
///
/// object はデータフォルダの標準化した絶対パス（別のデータフォルダで動く別のインスタンスには届かない）。
/// 中身は載せない。受けた側は一覧を読み直し、秘密の自動消去を掛け直す。誰が送っても読み直すだけなので害はない
public enum HistoryChangeSignal {
    public static let name = Notification.Name("com.takushio2525.makurip.historyDidChange")
    /// AI の操作の記録が増えた（設定画面の「AI の口」の記録を描き直す）
    public static let activityName = Notification.Name("com.takushio2525.makurip.aiActivity")

    public static func object(for directory: URL) -> String {
        directory.standardizedFileURL.path
    }

    public static func post(directory: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: object(for: directory), userInfo: nil, deliverImmediately: true)
    }

    public static func postActivity(directory: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            activityName, object: object(for: directory), userInfo: nil, deliverImmediately: true)
    }
}
