import Foundation

/// 一覧の「コピー方法」の絞り込み。⌘K で すべて → キー操作 → ボタンなど の順に切り替える
public enum CopyMethodFilter: String, CaseIterable, Sendable, Hashable {
    case all
    /// ⌘C / ⌘X でコピーしたものだけ
    case keyboard
    /// コピーボタン・メニューなど、キー以外でコピーしたものだけ（判定できなかった「不明」は含めない）
    case other

    public var next: CopyMethodFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public func accepts(_ method: CopyMethod) -> Bool {
        switch self {
        case .all: true
        case .keyboard: method == .keyboard
        case .other: method == .other
        }
    }
}

/// 一覧の絞り込みの条件（種類・コピー方法・アプリ・ピン留め・検索語）。判定は純粋関数
public struct HistoryFilter: Hashable, Sendable {
    /// nil は「すべて」
    public var kind: ClipKind?
    public var method: CopyMethodFilter
    /// コピー元アプリ（`HistoryFilter.appKey(of:)` の値）。nil は「すべて」
    public var app: String?
    public var pinnedOnly: Bool
    public var query: SearchQuery

    public init(
        kind: ClipKind? = nil, method: CopyMethodFilter = .all, app: String? = nil, pinnedOnly: Bool = false,
        query: SearchQuery = .empty
    ) {
        self.kind = kind
        self.method = method
        self.app = app
        self.pinnedOnly = pinnedOnly
        self.query = query
    }

    /// 種類のタブの並び（試作と同じ。nil が「すべて」。「その他」はタブを持たず「すべて」にだけ出る）
    public static let kindTabs: [ClipKind?] = [nil, .text, .richText, .image, .code, .command, .url, .file, .color]

    /// アプリを見分ける鍵（バンドル ID。なければ名前）
    public static func appKey(of source: SourceApp?) -> String? {
        source?.bundleID ?? source?.name
    }

    /// 検索の対象にする文字列（正規化済み）。一覧の平文・アプリ名・種類名・コピー元ページのホスト名
    public static func haystack(for item: ClipItem) -> String {
        var parts: [String] = []
        if let text = item.previewText { parts.append(text) }
        if let name = item.source?.name { parts.append(name) }
        parts.append(item.kind.label)
        if let host = item.sourceURL.flatMap({ URL(string: $0)?.host }) { parts.append(host) }
        return SearchText.normalize(parts.joined(separator: "\n"))
    }

    /// 1 件が条件に合うか。`haystack` は `HistoryFilter.haystack(for:)` の値
    public func matches(_ item: ClipItem, haystack: String, ignoringKind: Bool = false, ignoringApp: Bool = false)
        -> Bool
    {
        matches(item, ignoringKind: ignoringKind, ignoringApp: ignoringApp) { _ in haystack }
    }

    /// 検索語があるときだけ `haystack` を呼ぶ（正規化は重いので、検索語が空なら作らない）
    func matches(
        _ item: ClipItem, ignoringKind: Bool = false, ignoringApp: Bool = false, haystack: (ClipItem) -> String
    ) -> Bool {
        if pinnedOnly, !item.isPinned { return false }
        if !ignoringKind, let kind, item.kind != kind { return false }
        if !method.accepts(item.copyMethod) { return false }
        if !ignoringApp, let app, Self.appKey(of: item.source) != app { return false }
        return query.isEmpty || query.matches(normalized: haystack(item))
    }

    /// 条件に合うものを元の並び（新しい順）のまま返す
    public func apply(to items: [ClipItem], haystack: (ClipItem) -> String) -> [ClipItem] {
        items.filter { matches($0, haystack: haystack) }
    }

    /// 種類ごとの件数（種類以外の条件はかけたまま）。キー nil が「すべて」
    public func kindCounts(in items: [ClipItem], haystack: (ClipItem) -> String) -> [ClipKind?: Int] {
        var counts: [ClipKind?: Int] = [nil: 0]
        for item in items where matches(item, ignoringKind: true, haystack: haystack) {
            counts[nil, default: 0] += 1
            counts[item.kind, default: 0] += 1
        }
        return counts
    }

    /// アプリの選択肢（アプリ以外の条件はかけたまま）。件数の多い順、同数は名前順。先頭に「すべてのアプリ」
    public func appOptions(in items: [ClipItem], haystack: (ClipItem) -> String) -> [AppOption] {
        var counts: [String: Int] = [:]
        var sources: [String: SourceApp] = [:]
        var total = 0
        for item in items where matches(item, ignoringApp: true, haystack: haystack) {
            total += 1
            guard let key = Self.appKey(of: item.source), let source = item.source else { continue }
            counts[key, default: 0] += 1
            if sources[key] == nil { sources[key] = source }
        }
        let apps = counts.keys
            .map {
                AppOption(key: $0, name: sources[$0]?.name ?? $0, bundleID: sources[$0]?.bundleID, count: counts[$0]!)
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        return [AppOption(key: nil, name: "すべてのアプリ", bundleID: nil, count: total)] + apps
    }
}

/// アプリの選択肢 1 つ（⌘E）
public struct AppOption: Hashable, Sendable, Identifiable {
    /// nil は「すべてのアプリ」
    public var key: String?
    public var name: String
    public var bundleID: String?
    public var count: Int

    public var id: String { key ?? "" }

    public init(key: String?, name: String, bundleID: String?, count: Int) {
        self.key = key
        self.name = name
        self.bundleID = bundleID
        self.count = count
    }

    /// アプリ名の検索（ひらがな・ローマ字でも引ける。試作の ⌘E と同じく「すべてのアプリ」も名前で照合する）
    public func matches(_ query: SearchQuery) -> Bool {
        query.matches(normalized: SearchText.normalize(name))
    }
}
