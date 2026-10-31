import Foundation

/// 定型文（#7）の道具。定型文のファイル（`snippets.json`）を、定型文の窓と同じ検証（`SnippetCollection`）で読み書きする。
///
/// - 履歴と同じく、AI の口がオンのときだけ使える（定型文もユーザーのデータなので）
/// - 一覧は名前・略語・形式の情報（長さ・行数・差し込み）だけで、**本文は返さない**。名前を付けずに登録したもの（名前が本文の
///   1 行目）は名前も返さない。本文か名前が秘密っぽければ名前と略語を伏せ字にし、大きさ（文字数・行数）も返さない（履歴と同じ）
/// - 動いている Makurip はファイルの変化を見て読み直す（知らせる必要はない）
extension AITools {
    func addSnippet(_ args: Arguments) throws -> Output {
        try args.only(["body", "name", "abbreviation"])
        guard let body = try args.string("body") else { throw AIToolError.invalid("body（定型文の本文）がありません。") }
        let draft = SnippetDraft(
            name: try args.string("name") ?? "", abbreviation: try args.string("abbreviation") ?? "", body: body)
        let file = SnippetFile(directory: gateway.directory)
        let contents = file.load(now: Date())
        var collection = contents.collection
        let snippet: Snippet
        do {
            snippet = try collection.add(draft, now: Date())
        } catch let error as SnippetError {
            throw AIToolError.invalid(error.message)
        }
        do {
            try file.save(collection, backingUp: contents.needsBackup)
        } catch {
            throw AIToolError(.unavailable, "定型文のファイルに書けませんでした。")
        }
        let info = Self.describe(snippet)
        let message =
            (info.objectValue?["name"]?.stringValue.map { "定型文「\($0)」を登録しました" } ?? "定型文を登録しました（名前は本文の 1 行目）")
            + "。一覧の ⌘S で使えます。"
        var structured = info.objectValue ?? [:]
        structured["message"] = .string(message)
        return Output(structured: .object(structured), summary: "定型文を 1 件登録しました。")
    }

    func listSnippets(_ args: Arguments) throws -> Output {
        try args.only(["limit"])
        let limit = try args.int("limit", in: 1...SnippetCollection.maxCount) ?? 100
        let collection = SnippetFile(directory: gateway.directory).load(now: Date()).collection
        let items = collection.snippets.prefix(limit).map(Self.describe)
        let message = "定型文 \(collection.count) 件のうち \(items.count) 件の名前と形式の情報を返しました（本文は返しません）。"
        return Output(
            structured: .object([
                "total": .int(collection.count), "returned": .int(items.count), "items": .array(items),
                "message": .string(message),
            ]), summary: message)
    }

    func deleteSnippets(_ args: Arguments) throws -> Output {
        try args.only(["ids"])
        guard let texts = try args.stringArray("ids"), !texts.isEmpty else {
            throw AIToolError.invalid("ids（list_snippets の id の並び）がありません。")
        }
        let ids = try texts.map { text in
            guard let id = UUID(uuidString: text) else {
                throw AIToolError.invalid("ids の要素は list_snippets が返した id（UUID）にしてください。")
            }
            return id
        }
        let file = SnippetFile(directory: gateway.directory)
        let contents = file.load(now: Date())
        var collection = contents.collection
        var removed = 0
        for id in Set(ids) where (try? collection.remove(id: id)) != nil { removed += 1 }
        if removed > 0 {
            do {
                try file.save(collection, backingUp: contents.needsBackup)
            } catch {
                throw AIToolError(.unavailable, "定型文のファイルに書けませんでした。")
            }
        }
        let message = "定型文を \(removed) 件消しました。"
        return Output(structured: .object(["deleted": .int(removed), "message": .string(message)]), summary: message)
    }

    /// 定型文 1 件の名前と形式の情報（本文は入れない）。
    /// 名前を付けずに登録したものは名前が本文の 1 行目なので、名前も返さない（`nameFromBody`）。
    /// 秘密っぽければ文字数・行数を返さず `size: "hidden"`（長さで候補を絞れるため。履歴の一覧と同じ）
    static func describe(_ snippet: Snippet) -> JSONValue {
        let secret =
            !SecretDetector.findings(in: snippet.body).isEmpty || !SecretDetector.findings(in: snippet.name).isEmpty
        let fromBody = snippet.name == SnippetCollection.derivedName(from: snippet.body)
        var object: [String: JSONValue] = [
            "id": .string(snippet.id.uuidString),
            "nameFromBody": .bool(fromBody),
            "placeholders": .array(SnippetTemplate.placeholders(in: snippet.body).map { .string($0.rawValue) }),
            "createdAt": .string(AIGateway.iso(snippet.createdAt)),
            "updatedAt": .string(AIGateway.iso(snippet.updatedAt)),
            "secretLikely": .bool(secret),
        ]
        if secret {
            object["size"] = .string("hidden")
        } else {
            object["characters"] = .int(snippet.body.count)
            object["lines"] = .int(snippet.body.split(separator: "\n", omittingEmptySubsequences: false).count)
        }
        if !fromBody {
            object["name"] = .string(secret ? SecretMask.masked(snippet.name).text : snippet.name)
        }
        if !snippet.abbreviation.isEmpty {
            object["abbreviation"] = .string(
                secret ? SecretMask.masked(snippet.abbreviation).text : snippet.abbreviation)
        }
        return .object(object)
    }

    static let snippetTools: [Tool] = [
        Tool(
            name: Name.addSnippet, title: "定型文を登録",
            description:
                "Makurip の定型文（一覧の ⌘S で貼れる決まった文）を 1 件登録する（例:「いつもの挨拶文を定型文にして」）。body は本文（10 万文字まで）。name を省くと本文の 1 行目が名前になる。abbreviation は検索で引く略語（空白なし。例: ;sig）。本文の {{日付}}・{{クリップボード}}・{{言語}}・{{カーソル}} は貼るときに置き換わる。定型文は履歴とは別に残り、上限や履歴の消去では消えない。AI の口がオンのときだけ使える。",
            inputSchema: schema(
                [
                    "body": property("string", "本文"),
                    "name": property("string", "名前（100 文字まで。省くと本文の 1 行目）"),
                    "abbreviation": property("string", "略語（空白なし・32 文字まで）"),
                ], required: ["body"]), needsAccess: true, readOnly: false, destructive: false, logged: true),
        Tool(
            name: Name.listSnippets, title: "定型文の一覧",
            description:
                "Makurip の定型文を一覧の順に、名前・略語・形式の情報（文字数・行数・差し込み・時刻）だけで返す。本文は返さない（名前を付けずに登録したものは、名前も本文の 1 行目なので返さない。nameFromBody: true）。秘密っぽい定型文は名前を伏せ字にし、文字数・行数も返さない（size: hidden）。AI の口がオンのときだけ使える。",
            inputSchema: schema([
                "limit": property("integer", "返す件数（既定 100）", extra: ["minimum": .int(1), "maximum": .int(5000)])
            ]), needsAccess: true, readOnly: true, destructive: false, logged: true),
        Tool(
            name: Name.deleteSnippets, title: "定型文を消す",
            description: "Makurip の定型文を消す。ids は list_snippets が返した id の並び。返すのは消した件数だけ。消したものは元に戻せない。AI の口がオンのときだけ使える。",
            inputSchema: schema(
                [
                    "ids": property(
                        "array", "消す定型文の id の並び", extra: ["items": .object(["type": .string("string")])])
                ], required: ["ids"]), needsAccess: true, readOnly: false, destructive: true, logged: true),
    ]
}
