import Foundation

/// 起動引数。一覧は `.agent/api.md` の「起動引数」。
///
/// `open -n Makurip.app --args ...` で渡す。macOS が足す `-psn_...` や `-NSDocumentRevisionsDebugMode` などの
/// 知らない引数は読み飛ばす。
struct LaunchOptions {
    /// `--data-dir PATH`（隔離したデータフォルダ）。環境変数 `MAKURIP_DATA_DIR` でも指定できる
    var dataDirectory: String?
    /// `--pasteboard-name NAME`（一般ペーストボードの代わりに名前付きペーストボードを監視・書き戻しする。検証用）
    var pasteboardName: String?
    /// `--dump-metadata`（保存済み項目のメタデータだけを JSON で標準出力に書いて終わる。中身は出さない）
    var dumpMetadata = false
    /// `--debug-control`（E2E 用の遠隔操作を受け付ける。`--data-dir` を指定したときだけ有効）
    var debugControl = false
    /// `--settings <命令> ...`（設定の CLI。後ろの引数は `--data-dir` を除いてすべて CLI に渡す）
    var settingsArguments: [String]?
    /// `--mcp`（AI の口の MCP サーバー。標準入出力の JSON-RPC）
    var mcp = false
    /// `--ai <命令> ...`（AI の口の CLI。後ろの引数は `--data-dir`・`--pasteboard-name` を除いてすべて CLI に渡す）
    var aiArguments: [String]?
    /// `--update <命令> ...`（アップデートの CLI。status / check / apply）
    var updateArguments: [String]?
    /// `--update-feed URL`（版を問い合わせる先の差し替え。`--data-dir` を指定したときだけ有効。検証用）
    var updateFeed: String?
    /// `--update-allow-unnotarized`（公証のない版も入れる。`--data-dir` と `--update-feed` がそろったときだけ有効。検証用）
    var allowUnnotarizedUpdate = false
    /// `-MakuripPanelScreen NAME`（UserDefaults の引数ドメインで読む。起動し直すときに渡し直すためだけに控える）
    var panelScreen: String?

    /// どれかの CLI の後ろか（後ろの引数はその CLI に渡す）
    private var inCLI: Bool { settingsArguments != nil || aiArguments != nil || updateArguments != nil }

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--data-dir": options.dataDirectory = iterator.next()
            case "--pasteboard-name": options.pasteboardName = iterator.next()
            case "--dump-metadata": options.dumpMetadata = true
            case "--debug-control": options.debugControl = true
            case "--update-feed": options.updateFeed = iterator.next()
            case "--update-allow-unnotarized": options.allowUnnotarizedUpdate = true
            case "-MakuripPanelScreen" where !options.inCLI: options.panelScreen = iterator.next()
            case "--settings" where options.aiArguments == nil && options.updateArguments == nil:
                options.settingsArguments = options.settingsArguments ?? []
            case "--mcp" where !options.inCLI: options.mcp = true
            case "--ai" where options.settingsArguments == nil && options.updateArguments == nil:
                options.aiArguments = options.aiArguments ?? []
            case "--update" where options.settingsArguments == nil && options.aiArguments == nil:
                options.updateArguments = options.updateArguments ?? []
            default:
                // --settings・--ai・--update の後ろは CLI の引数（--json などもそのまま渡す）
                if options.settingsArguments != nil {
                    options.settingsArguments?.append(argument)
                } else if options.aiArguments != nil {
                    options.aiArguments?.append(argument)
                } else if options.updateArguments != nil {
                    options.updateArguments?.append(argument)
                }
            }
        }
        return options
    }

    /// アップデートの後に起動し直すとき渡す引数（隔離したインスタンスは、同じデータフォルダ・配信元・検証の口で起き直す）
    var relaunchArguments: [String] {
        var arguments: [String] = []
        if let dataDirectory { arguments += ["--data-dir", dataDirectory] }
        if let pasteboardName { arguments += ["--pasteboard-name", pasteboardName] }
        if debugControl { arguments.append("--debug-control") }
        if let updateFeed { arguments += ["--update-feed", updateFeed] }
        if allowUnnotarizedUpdate { arguments.append("--update-allow-unnotarized") }
        if let panelScreen { arguments += ["-MakuripPanelScreen", panelScreen] }
        return arguments
    }
}
