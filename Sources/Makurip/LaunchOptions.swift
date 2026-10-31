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

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--data-dir": options.dataDirectory = iterator.next()
            case "--pasteboard-name": options.pasteboardName = iterator.next()
            case "--dump-metadata": options.dumpMetadata = true
            case "--debug-control": options.debugControl = true
            case "--settings" where options.aiArguments == nil:
                options.settingsArguments = options.settingsArguments ?? []
            case "--mcp" where options.settingsArguments == nil && options.aiArguments == nil: options.mcp = true
            case "--ai" where options.settingsArguments == nil: options.aiArguments = options.aiArguments ?? []
            default:
                // --settings・--ai の後ろは CLI の引数（--json などもそのまま渡す）
                if options.settingsArguments != nil {
                    options.settingsArguments?.append(argument)
                } else if options.aiArguments != nil {
                    options.aiArguments?.append(argument)
                }
            }
        }
        return options
    }
}
