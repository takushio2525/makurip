import Foundation

/// 呼び出しキー（⌃⌘V）を押したときの動き。ID（rawValue）は試作（core.js の `Mk.PREFS` の `hotkeyMode`）と同じ。
/// 選ぶ画面は設定（#4）で作る。いまは UserDefaults の `hotkeyMode` で切り替えられる（`.agent/api.md`）
public enum HotKeyMode: String, CaseIterable, Sendable, Codable {
    /// 最新の履歴をそのまま貼る。窓は出さない
    case pasteOnly = "paste"
    /// 最新を貼り、文字カーソルの横に候補窓を出す（既定）
    case candidate
    /// 貼らずに一覧（パネル）を開く
    case list

    public var label: String {
        switch self {
        case .pasteOnly: "すぐ貼るだけ"
        case .candidate: "すぐ貼って候補窓"
        case .list: "一覧を開く"
        }
    }

    public var summary: String {
        switch self {
        case .pasteOnly: "最新の履歴をそのまま貼る。窓は出さない。一覧は「一覧を開く」のキーで開く。"
        case .candidate: "最新を貼り、文字カーソルの横に候補窓を出す。↑↓ で貼り替え、Tab で確定。"
        case .list: "貼らずに履歴の一覧（パネル）を開く。"
        }
    }
}

/// 候補窓の並び。ID は試作の `candOrder` と同じ
public enum CandidateOrder: String, CaseIterable, Sendable, Codable {
    /// 最新がいちばん下。↑ で 1 つ古い履歴へ（既定。ユーザーの「ターミナルみたいに」）
    case terminal
    /// 最新がいちばん上。↓ で 1 つ古い履歴へ（予測変換の見た目）
    case ime

    public var label: String {
        switch self {
        case .terminal: "ターミナル式"
        case .ime: "予測変換式"
        }
    }
}

/// 候補窓を出したとき、いつ前面のアプリに貼るか
public enum PasteTiming: String, CaseIterable, Sendable, Codable {
    /// すぐ仮に貼り、↑↓ で差し替える（既定）
    case immediate
    /// ↑↓ の間は候補窓で見せるだけにし、確定（Tab・Enter）したときに初めて貼る（ターミナル・チャットの既定）
    case onCommit
}

/// 候補窓まわりの設定。設定スキーマ（#4）ができるまでは UserDefaults から読む。
///
/// キーは試作の `Mk.PREFS` の ID に合わせた（`hotkeyMode`・`candOrder`）。アプリごとの上書きは辞書で持つ。
/// 秘密は入らないので、AI（#6）が読み書きしてよい
public struct CandidateSettings: Hashable, Sendable {
    public var hotKeyMode: HotKeyMode
    public var order: CandidateOrder
    /// アプリごとの貼り方（既定の一覧 `DeferredPasteApps` より優先）。キーはバンドル ID
    public var pasteTiming: [String: PasteTiming]
    /// アプリごとの差し替え方式を決め打ちする（自動の判定より優先）。キーはバンドル ID
    public var replaceMethod: [String: ReplaceMethod]
    /// 何も押さないまま、この秒数がたったら確定して閉じる（横取りを残さないため）
    public var idleTimeout: TimeInterval

    public init(
        hotKeyMode: HotKeyMode = .candidate, order: CandidateOrder = .terminal,
        pasteTiming: [String: PasteTiming] = [:], replaceMethod: [String: ReplaceMethod] = [:],
        idleTimeout: TimeInterval = 10
    ) {
        self.hotKeyMode = hotKeyMode
        self.order = order
        self.pasteTiming = pasteTiming
        self.replaceMethod = replaceMethod
        self.idleTimeout = idleTimeout
    }

    public static let `default` = CandidateSettings()

    /// UserDefaults のキー
    public enum Key {
        public static let hotKeyMode = "hotkeyMode"
        public static let order = "candOrder"
        public static let pasteTiming = "candPasteTiming"
        public static let replaceMethod = "candReplaceMethod"
        public static let idleTimeout = "candIdleTimeout"
    }

    /// そのアプリでの貼り方。上書きがなければ、ターミナルとチャットは確定まで貼らない
    public func timing(for bundleID: String?) -> PasteTiming {
        if let bundleID, let override = pasteTiming[bundleID] { return override }
        return DeferredPasteApps.category(of: bundleID) == nil ? .immediate : .onCommit
    }

    public func replaceOverride(for bundleID: String?) -> ReplaceMethod? {
        bundleID.flatMap { replaceMethod[$0] }
    }

    /// 壊れた値・知らない値は無視して既定に戻す
    public static func load(from defaults: UserDefaults) -> CandidateSettings {
        var settings = CandidateSettings()
        if let raw = defaults.string(forKey: Key.hotKeyMode), let mode = HotKeyMode(rawValue: raw) {
            settings.hotKeyMode = mode
        }
        if let raw = defaults.string(forKey: Key.order), let order = CandidateOrder(rawValue: raw) {
            settings.order = order
        }
        if let raw = defaults.dictionary(forKey: Key.pasteTiming) {
            settings.pasteTiming = raw.compactMapValues { ($0 as? String).flatMap(PasteTiming.init(rawValue:)) }
        }
        if let raw = defaults.dictionary(forKey: Key.replaceMethod) {
            settings.replaceMethod = raw.compactMapValues { ($0 as? String).flatMap(ReplaceMethod.init(rawValue:)) }
        }
        let timeout = defaults.double(forKey: Key.idleTimeout)
        if timeout >= 2, timeout <= 120 { settings.idleTimeout = timeout }
        return settings
    }
}

/// 候補窓で、確定するまで貼らないのを既定にするアプリ（ユーザーの決定: ターミナルとチャット系）。
///
/// - ターミナル: 改行を含む中身を貼るとその場で実行されうる（bracketed paste が無効なシェル）。⌘Z も効かない
/// - チャット: Enter で送信される・画像を貼ると送信の確認が開く・相手に入力中と見える
///
/// バンドル ID は 2026-10-31 に手元の .app の Info.plist で確かめた（「未確認」と書いたものは手元に無く、公開の値）。
/// アプリごとの変更は `CandidateSettings.pasteTiming`（設定画面は #4）
public enum DeferredPasteApps {
    public enum Category: String, Sendable {
        case terminal
        case chat
    }

    public struct App: Hashable, Sendable {
        public let bundleID: String
        public let name: String
        public let category: Category
    }

    public static let terminals: [App] = [
        App(bundleID: "com.apple.Terminal", name: "ターミナル", category: .terminal),
        App(bundleID: "com.googlecode.iterm2", name: "iTerm2", category: .terminal),
        App(bundleID: "dev.warp.Warp-Stable", name: "Warp", category: .terminal),  // 未確認
        App(bundleID: "com.mitchellh.ghostty", name: "Ghostty", category: .terminal),
        App(bundleID: "dev.takushio.tako", name: "tako", category: .terminal),
        App(bundleID: "org.alacritty", name: "Alacritty", category: .terminal),  // 未確認
        App(bundleID: "net.kovidgoyal.kitty", name: "kitty", category: .terminal),  // 未確認
        App(bundleID: "com.github.wez.wezterm", name: "WezTerm", category: .terminal),  // 未確認
        App(bundleID: "co.zeit.hyper", name: "Hyper", category: .terminal),  // 未確認
        App(bundleID: "org.tabby", name: "Tabby", category: .terminal),  // 未確認
    ]

    public static let chats: [App] = [
        App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", category: .chat),
        App(bundleID: "com.hnc.Discord", name: "Discord", category: .chat),
        App(bundleID: "jp.naver.line.mac", name: "LINE", category: .chat),
        App(bundleID: "com.apple.MobileSMS", name: "メッセージ", category: .chat),
        App(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", category: .chat),
        App(bundleID: "com.microsoft.teams", name: "Microsoft Teams（旧版）", category: .chat),  // 未確認
        App(bundleID: "com.openai.codex", name: "ChatGPT", category: .chat),  // 手元の ChatGPT.app はこの ID
        App(bundleID: "com.openai.chat", name: "ChatGPT（旧版）", category: .chat),  // 未確認
        App(bundleID: "com.anthropic.claudefordesktop", name: "Claude", category: .chat),
        App(bundleID: "ru.keepcoder.Telegram", name: "Telegram", category: .chat),  // 未確認
        App(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", category: .chat),  // 未確認
    ]

    public static let all: [App] = terminals + chats

    private static let byBundleID = Dictionary(
        all.map { ($0.bundleID.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

    /// バンドル ID の大文字・小文字は区別しない（アプリによって表記が揺れるため）
    public static func category(of bundleID: String?) -> Category? {
        bundleID.flatMap { byBundleID[$0.lowercased()]?.category }
    }
}
