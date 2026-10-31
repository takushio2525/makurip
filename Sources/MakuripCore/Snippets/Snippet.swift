import Foundation

/// 定型文 1 件。履歴とは別のファイル（`snippets.json`）に持ち、履歴の上限・消去では消えない。
///
/// 本文の `{{日付}}`・`{{クリップボード}}`・`{{言語}}`・`{{カーソル}}` は貼るときに置き換える（`SnippetTemplate`）
public struct Snippet: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 一覧のカードの 1 行目（太字）。同じ名前があってもよい
    public var name: String
    /// 略語（例: `;date`）。検索で引けるようにするためのもの。空なら出さない
    public var abbreviation: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, name: String, abbreviation: String, body: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.abbreviation = abbreviation
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var draft: SnippetDraft {
        SnippetDraft(name: name, abbreviation: abbreviation, body: body)
    }
}

/// 登録・編集で入れる値（検証前）
public struct SnippetDraft: Hashable, Sendable {
    public var name: String
    public var abbreviation: String
    public var body: String

    public init(name: String = "", abbreviation: String = "", body: String = "") {
        self.name = name
        self.abbreviation = abbreviation
        self.body = body
    }
}

/// 定型文の登録・編集で通らなかった理由（人と AI が読んで直せる文）
public struct SnippetError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Field: String, Sendable {
        case name
        case abbreviation
        case body
        case list
    }

    public let field: Field
    public let message: String

    public init(_ field: Field, _ message: String) {
        self.field = field
        self.message = message
    }

    public var description: String { message }
}

/// 定型文の並び（ファイルに書く順 = 一覧の順）と、登録・編集・削除・並べ替え。
///
/// UI に依存しない値の型。設定画面・定型文の窓・AI の口（#6）が同じ関数を通す（検証はここの `normalize` だけ）
public struct SnippetCollection: Hashable, Sendable {
    public private(set) var snippets: [Snippet]

    /// 本文の長さの上限（UTF-16）。貼る文としては十分に大きく、ファイルが極端に大きくならない程度
    public static let maxBodyLength = 100_000
    public static let maxNameLength = 100
    public static let maxAbbreviationLength = 32
    public static let maxCount = 5000
    /// 名前を空にしたとき、本文の 1 行目から作る名前の長さ
    static let derivedNameLength = 40

    public init(_ snippets: [Snippet] = []) {
        self.snippets = snippets
    }

    public var isEmpty: Bool { snippets.isEmpty }
    public var count: Int { snippets.count }

    public func snippet(id: UUID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    public func index(of id: UUID) -> Int? {
        snippets.firstIndex { $0.id == id }
    }

    // MARK: 検証

    /// 値を確かめ、保存する形にそろえる。
    ///
    /// - 本文: 空白と改行だけなら不可。上限を超えたら不可。中身はそのまま（末尾の改行も意図として残す）
    /// - 名前: 前後の空白を除き、改行は空白に。空なら本文の 1 行目から作る
    /// - 略語: 前後の空白を除く。途中の空白・改行は不可（検索の語として 1 語にするため）
    public static func normalize(_ draft: SnippetDraft) -> Result<SnippetDraft, SnippetError> {
        let body = draft.body
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(SnippetError(.body, "本文が空。貼りたい文を書く"))
        }
        if body.utf16.count > maxBodyLength {
            return .failure(
                SnippetError(.body, "本文が長すぎる（\(maxBodyLength) 文字まで。いま \(body.utf16.count) 文字）"))
        }
        var name = draft.name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = derivedName(from: body) }
        if name.count > maxNameLength {
            return .failure(SnippetError(.name, "名前が長すぎる（\(maxNameLength) 文字まで。いま \(name.count) 文字）"))
        }
        let abbreviation = draft.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        if abbreviation.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return .failure(SnippetError(.abbreviation, "略語に空白や改行は入れられない（例: ;date）"))
        }
        if abbreviation.count > maxAbbreviationLength {
            return .failure(
                SnippetError(.abbreviation, "略語が長すぎる（\(maxAbbreviationLength) 文字まで。いま \(abbreviation.count) 文字）"))
        }
        return .success(SnippetDraft(name: name, abbreviation: abbreviation, body: body))
    }

    /// 本文の最初の空でない行（長ければ切って「…」）
    public static func derivedName(from body: String) -> String {
        let line =
            body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > derivedNameLength else { return line }
        return String(line.prefix(derivedNameLength)) + "…"
    }

    // MARK: 登録・編集・削除・並べ替え

    /// 足す。`index` を省くと末尾。足した 1 件を返す
    @discardableResult
    public mutating func add(_ draft: SnippetDraft, at index: Int? = nil, now: Date, id: UUID = UUID()) throws
        -> Snippet
    {
        guard snippets.count < Self.maxCount else {
            throw SnippetError(.list, "定型文は \(Self.maxCount) 件まで。使わないものを消してから足す")
        }
        let value = try Self.normalize(draft).get()
        let snippet = Snippet(
            id: snippets.contains { $0.id == id } ? UUID() : id, name: value.name, abbreviation: value.abbreviation,
            body: value.body, createdAt: now, updatedAt: now)
        let position = min(max(0, index ?? snippets.count), snippets.count)
        snippets.insert(snippet, at: position)
        return snippet
    }

    /// 名前・略語・本文を書き換える。中身が同じなら何もしない（更新時刻も変えない）
    @discardableResult
    public mutating func update(id: UUID, with draft: SnippetDraft, now: Date) throws -> Snippet {
        guard let index = index(of: id) else { throw SnippetError(.list, "その定型文はない（消されたかもしれない）") }
        let value = try Self.normalize(draft).get()
        var snippet = snippets[index]
        guard snippet.draft != value else { return snippet }
        snippet.name = value.name
        snippet.abbreviation = value.abbreviation
        snippet.body = value.body
        snippet.updatedAt = now
        snippets[index] = snippet
        return snippet
    }

    /// 消す。消した 1 件を返す
    @discardableResult
    public mutating func remove(id: UUID) throws -> Snippet {
        guard let index = index(of: id) else { throw SnippetError(.list, "その定型文はない（消されたかもしれない）") }
        return snippets.remove(at: index)
    }

    /// `id` の定型文を `index` 番目へ動かす（範囲の外は端に寄せる）
    public mutating func move(id: UUID, to index: Int) throws {
        guard let from = self.index(of: id) else { throw SnippetError(.list, "その定型文はない（消されたかもしれない）") }
        let snippet = snippets.remove(at: from)
        snippets.insert(snippet, at: min(max(0, index), snippets.count))
    }

    /// 1 つ上（`delta` < 0）・下（> 0）へ動かす。端なら何もしない。動いたら true
    @discardableResult
    public mutating func move(id: UUID, by delta: Int) throws -> Bool {
        guard let from = index(of: id) else { throw SnippetError(.list, "その定型文はない（消されたかもしれない）") }
        let to = min(max(0, from + delta), snippets.count - 1)
        guard to != from else { return false }
        try move(id: id, to: to)
        return true
    }
}

extension Snippet {
    /// 検索の対象にする文字列（正規化済み）。名前・略語・本文と「定型文」（試作と同じ）
    public var searchHaystack: String {
        SearchText.normalize([name, abbreviation, body, "定型文"].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}
