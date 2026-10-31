import Foundation
import MakuripCore

/// 一覧に出す文言（純粋関数）。試作（core.js の Mk.rel・Mk.abs・Mk.group・Mk.infoText）と同じ書き方
enum DisplayText {
    /// 日付の区切り（今日・昨日・それ以前）
    enum DayGroup: String, CaseIterable {
        case today = "今日"
        case yesterday = "昨日"
        case older = "それ以前"
    }

    static func dayOffset(_ date: Date, now: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day
        return max(0, days ?? 0)
    }

    static func group(_ date: Date, now: Date, calendar: Calendar = .current) -> DayGroup {
        switch dayOffset(date, now: now, calendar: calendar) {
        case 0: .today
        case 1: .yesterday
        default: .older
        }
    }

    /// 相対時刻（たった今・5分前・3時間前・昨日・4日前・10月21日）
    static func relative(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let minutes = now.timeIntervalSince(date) / 60
        if minutes < 1 { return "たった今" }
        if minutes < 60 { return "\(Int(minutes.rounded()))分前" }
        let days = dayOffset(date, now: now, calendar: calendar)
        switch days {
        case 0: return "\(Int(minutes / 60))時間前"
        case 1: return "昨日"
        case 2..<7: return "\(days)日前"
        default:
            let parts = calendar.dateComponents([.month, .day], from: date)
            return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
        }
    }

    /// 日時（今日 15:25・昨日 9:03・10月21日 18:40）
    static func absolute(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let time = "\(parts.hour ?? 0):" + String(format: "%02d", parts.minute ?? 0)
        switch dayOffset(date, now: now, calendar: calendar) {
        case 0: return "今日 \(time)"
        case 1: return "昨日 \(time)"
        default: return "\(parts.month ?? 0)月\(parts.day ?? 0)日 \(time)"
        }
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func lineCount(_ text: String) -> Int {
        codeText(text).split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// コード・コマンドを出すときの文字列。改行を \n にそろえ（\r\n は Swift では 1 文字になり \n で分けられない）、
    /// タブを空白 4 つにする
    static func codeText(_ text: String) -> String {
        // contains は Character で比べるので \r\n の中の \r を見つけない。バイトで探す
        var result = text
        if result.utf8.contains(13) {
            result = result.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        if result.utf8.contains(9) { result = result.replacingOccurrences(of: "\t", with: "    ") }
        return result
    }

    /// コピー元のページの表示（ホストと、その後ろのパス）。http・https でホストがあるときだけ
    static func sourcePage(_ string: String?) -> (host: String, path: String)? {
        guard let string, let components = URLComponents(string: string),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        // クエリ（? の後ろ）は出さない。トークンなどの秘密が入りうるため（--dump-metadata もホストだけ）
        var path = components.percentEncodedPath
        if path == "/" { path = "" }
        return (host, path.removingPercentEncoding ?? path)
    }

    /// 内容の要点（プレビューの見出しと詳細に出す）。`detail` があれば全文で数える
    static func info(for item: ClipItem, detail: ClipDetail?) -> String {
        let text = detail?.fullText ?? item.previewText ?? ""
        let characters = detail?.totalCharacterCount ?? text.count
        let lines = "\(detail?.totalLineCount ?? lineCount(text)) 行"
        switch item.kind {
        case .text:
            return "\(characters) 文字"
        case .richText:
            return "リッチテキスト · \(characters) 文字"
        case .code:
            return detail?.language.map { "\($0.displayName) · \(lines)" } ?? lines
        case .command:
            return (detail?.promptCount ?? 0) > 0 ? lines + " · 貼るときに先頭の記号を外す" : lines
        case .image:
            guard let image = detail?.image else { return bytes(item.totalBytes) }
            return "\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height)) · \(image.format) · "
                + bytes(image.byteCount)
        case .url:
            return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? text
        case .file:
            return "\(max(item.pasteboardItemCount, detail?.files.count ?? 0)) 項目"
        case .color:
            return detail?.color.map { "HEX \($0.hex)" } ?? text
        case .other:
            return "その他のデータ · " + bytes(item.totalBytes)
        }
    }

    /// カードの下の行に出すコピー方法（キー操作は ⌘C と ⌘X を見分けていないので「キー」とだけ出す）
    static func methodShort(_ method: CopyMethod) -> String? {
        switch method {
        case .keyboard: "キー"
        case .other: "ボタン"
        case .unknown: nil
        }
    }

    /// 詳細に出すコピー方法
    static func methodLong(_ method: CopyMethod) -> String {
        switch method {
        case .keyboard: "キー操作（⌘C / ⌘X）"
        case .other: "コピーボタンなど（キー以外）"
        case .unknown: "不明（キー操作を見られなかった）"
        }
    }

    /// 「コピー方法」の絞り込みボタンの文言
    static func methodFilter(_ filter: CopyMethodFilter) -> String {
        switch filter {
        case .all: "コピー方法：すべて"
        case .keyboard: "キー操作のみ"
        case .other: "ボタンなどのみ"
        }
    }
}

// MARK: 定型文

extension DisplayText {
    /// ⌘Y の見出しの要点（試作の Mk.infoText: 「定型文 · 略語 ;date」。略語がなければ「定型文」）
    static func snippetInfo(_ snippet: Snippet) -> String {
        snippet.abbreviation.isEmpty ? "定型文" : "定型文 · 略語 \(snippet.abbreviation)"
    }

    /// 差し込みが置き換わることの説明（試作の .pv-note の文。日付は今日の日付を設定の書き方で）
    static func snippetNote(now: Date, format: SnippetDateFormat) -> String {
        "色の付いた部分は貼り付けるときに置き換わります（日付 → \(format.format(now))、クリップボード → 最新のテキスト）。"
    }
}
