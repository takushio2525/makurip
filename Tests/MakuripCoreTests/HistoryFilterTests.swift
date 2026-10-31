import Foundation
import Testing

@testable import MakuripCore

/// 絞り込みのテスト用の履歴（メタデータだけの自作データ）
func makeItem(
    _ kind: ClipKind, _ text: String?, method: CopyMethod = .keyboard, app: (String, String)? = ("com.example.a", "A"),
    pinned: Bool = false, minutesAgo: Double = 1, sourceURL: String? = nil
) -> ClipItem {
    let date = Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60)
    return ClipItem(
        id: UUID(), contentHash: UUID().uuidString, kind: kind, copyMethod: method,
        source: app.map { SourceApp(bundleID: $0.0, name: $0.1) }, sourceURL: sourceURL, createdAt: date,
        lastUsedAt: date, copyCount: 1, isPinned: pinned, flags: [], previewText: text, totalBytes: 10,
        pasteboardItemCount: 1)
}

@Suite("絞り込み")
struct HistoryFilterTests {
    let items: [ClipItem] = [
        makeItem(
            .command, "$ git switch -c feature/history-panel", method: .other, app: ("com.example.chat", "Claude")),
        makeItem(.code, "struct HistoryRow: View {", method: .keyboard, app: ("com.apple.dt.Xcode", "Xcode")),
        makeItem(.image, nil, method: .keyboard, app: ("com.apple.screenshot", "スクリーンショット"), pinned: true),
        makeItem(.text, "ﾃﾞﾌﾟﾛｲ手順：ビルド → 公証", method: .keyboard, app: ("com.apple.mail", "メール")),
        makeItem(.command, "% npm run build", method: .keyboard, app: ("com.apple.Terminal", "ターミナル"), pinned: true),
        makeItem(.text, "コピーボタンで写した文", method: .other, app: ("com.apple.Safari", "Safari")),
        makeItem(.text, "判定できなかった", method: .unknown, app: nil),
    ]

    func run(_ filter: HistoryFilter) -> [ClipItem] {
        filter.apply(to: items) { HistoryFilter.haystack(for: $0) }
    }

    @Test("条件なしなら全件を元の並びで返す")
    func noFilter() {
        #expect(run(HistoryFilter()) == items)
    }

    @Test("種類で絞る")
    func byKind() {
        #expect(run(HistoryFilter(kind: .command)).map(\.previewText) == [items[0].previewText, items[4].previewText])
        #expect(run(HistoryFilter(kind: .color)).isEmpty)
    }

    @Test("コピー方法で絞る（不明はキー操作にもボタンなどにも入らない）")
    func byMethod() {
        #expect(run(HistoryFilter(method: .keyboard)).count == 4)
        #expect(run(HistoryFilter(method: .other)).count == 2)
        #expect(!run(HistoryFilter(method: .keyboard)).contains { $0.copyMethod == .unknown })
        #expect(!run(HistoryFilter(method: .other)).contains { $0.copyMethod == .unknown })
        #expect(CopyMethodFilter.all.next == .keyboard)
        #expect(CopyMethodFilter.keyboard.next == .other)
        #expect(CopyMethodFilter.other.next == .all)
    }

    @Test("アプリ・ピン留めで絞る")
    func byAppAndPin() {
        #expect(run(HistoryFilter(app: "com.apple.Terminal")).count == 1)
        #expect(run(HistoryFilter(pinnedOnly: true)).count == 2)
    }

    @Test("組み合わせ: 種類 × コピー方法 × アプリ × ピン留め × 検索語はすべて AND")
    func combined() {
        var filter = HistoryFilter(kind: .command, method: .keyboard)
        #expect(run(filter).map(\.previewText) == ["% npm run build"])
        filter.pinnedOnly = true
        #expect(run(filter).count == 1)
        filter.app = "com.apple.Terminal"
        #expect(run(filter).count == 1)
        filter.query = SearchText.parse("npm")
        #expect(run(filter).count == 1)
        filter.query = SearchText.parse("git")
        #expect(run(filter).isEmpty)
        // ボタンなど × コマンド
        #expect(run(HistoryFilter(kind: .command, method: .other)).map(\.previewText) == [items[0].previewText])
        // 検索語 × 種類
        #expect(run(HistoryFilter(kind: .text, query: SearchText.parse("depuroi"))).count == 1)
        #expect(run(HistoryFilter(kind: .code, query: SearchText.parse("depuroi"))).isEmpty)
    }

    @Test("アプリ名・種類名でも探せる")
    func searchMetadata() {
        #expect(run(HistoryFilter(query: SearchText.parse("たーみなる"))).count == 1)
        #expect(run(HistoryFilter(query: SearchText.parse("xcode"))).count == 1)
        #expect(run(HistoryFilter(query: SearchText.parse("画像"))).count == 1)
    }

    @Test("種類ごとの件数は種類以外の条件をかけたまま数える")
    func kindCounts() {
        let filter = HistoryFilter(kind: .image, method: .keyboard)
        let counts = filter.kindCounts(in: items) { HistoryFilter.haystack(for: $0) }
        #expect(counts[nil] == 4)
        #expect(counts[.text] == 1)
        #expect(counts[.command] == 1)
        #expect(counts[.image] == 1)
        #expect(counts[.url] == nil)
    }

    @Test("アプリの選択肢は件数の多い順で、先頭が「すべてのアプリ」。ひらがな・ローマ字で探せる")
    func appOptions() {
        var many = items
        many.append(makeItem(.text, "もう 1 件", app: ("com.apple.Terminal", "ターミナル")))
        let options = HistoryFilter(app: "com.apple.Safari").appOptions(in: many) { HistoryFilter.haystack(for: $0) }
        #expect(options.first?.key == nil)
        #expect(options.first?.count == many.count)
        #expect(options[1].key == "com.apple.Terminal")
        #expect(options[1].count == 2)
        #expect(options.contains { $0.name == "Safari" })
        let terminal = options[1]
        #expect(terminal.matches(SearchText.parse("たーみなる")))
        #expect(terminal.matches(SearchText.parse("ta-minaru")))
        #expect(terminal.matches(SearchText.parse("ﾀｰﾐﾅﾙ")))
        #expect(!terminal.matches(SearchText.parse("めーる")))
        #expect(options.first(where: { $0.name == "メール" })?.matches(SearchText.parse("me-ru")) == true)
    }

    @Test("タブの並びは試作と同じ（すべて・テキスト・リッチ・画像・コード・コマンド・URL・ファイル・色）")
    func kindTabs() {
        #expect(HistoryFilter.kindTabs == [nil, .text, .richText, .image, .code, .command, .url, .file, .color])
    }
}
