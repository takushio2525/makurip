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

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--data-dir": options.dataDirectory = iterator.next()
            case "--pasteboard-name": options.pasteboardName = iterator.next()
            case "--dump-metadata": options.dumpMetadata = true
            case "--debug-control": options.debugControl = true
            default: continue
            }
        }
        return options
    }
}
