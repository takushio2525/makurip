import Foundation
import os

/// 表示名・バンドル ID は Info.plist（`Sources/Makurip/Info.plist`）だけに書き、ここで読む
enum AppIdentity {
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String)
            ?? "unknown.makurip"
    }

    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }
}

/// ログ。**中身（平文・データ）は絶対に書かない**。書いてよいのは種類・型の数・バイト数・理由などのメタデータだけ
enum Log {
    static let app = Logger(subsystem: AppIdentity.bundleID, category: "app")
    static let capture = Logger(subsystem: AppIdentity.bundleID, category: "capture")
    static let paste = Logger(subsystem: AppIdentity.bundleID, category: "paste")
}
