import Foundation

/// 秘密の確度。自動で消すのは `.high` だけ（誤判定で普通のテキストを消さないため）
public enum SecretConfidence: Int, Sendable, Comparable, Hashable {
    /// 形式から外れる長いランダムな文字列（マスクするが、自動では消さない）
    case medium = 1
    /// 既知の形式（API キーの接頭辞・秘密鍵・認証ヘッダー・.env の代入など）
    case high = 2

    public static func < (lhs: SecretConfidence, rhs: SecretConfidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 秘密と判定した理由（どの形式に当たったか）。中身は持たない
public enum SecretKind: String, Sendable, CaseIterable, Hashable {
    case anthropicKey
    case openAIKey
    case githubToken
    case gitlabToken
    case slackToken
    case slackWebhook
    case discordWebhook
    case awsAccessKey
    case googleAPIKey
    case googleOAuth
    case stripeKey
    case npmToken
    case huggingFaceToken
    case sendGridKey
    case jwt
    case privateKey
    case authorizationHeader
    case urlCredentials
    case passwordAssignment
    case secretAssignment
    case randomToken

    public var confidence: SecretConfidence { self == .randomToken ? .medium : .high }

    /// 画面に出す理由（「〜なので隠しています」に続く形）
    public var reason: String {
        switch self {
        case .anthropicKey, .openAIKey, .awsAccessKey, .googleAPIKey, .stripeKey, .sendGridKey: "API キーの形式"
        case .githubToken, .gitlabToken, .slackToken, .npmToken, .huggingFaceToken, .googleOAuth: "アクセストークンの形式"
        case .slackWebhook, .discordWebhook: "Webhook の URL の形式"
        case .jwt: "JWT（トークン）の形式"
        case .privateKey: "秘密鍵の形式"
        case .authorizationHeader: "認証ヘッダーの値"
        case .urlCredentials: "URL の中のパスワード"
        case .passwordAssignment: "パスワードらしき値"
        case .secretAssignment: "トークンらしき値"
        case .randomToken: "ランダムな文字列"
        }
    }

    /// 末尾の 4 文字を見せてよいか（GitHub などの管理画面と同じ。短いパスワードは見せない）
    var revealsTail: Bool {
        switch self {
        case .passwordAssignment, .urlCredentials, .privateKey: false
        default: true
        }
    }

    /// 重なったときに残す順（大きいほうを残す）。既知の形式 > ヘッダー・URL の中のパスワード > 代入 > ランダムな文字列
    var priority: Int {
        switch self {
        case .randomToken: 0
        case .passwordAssignment, .secretAssignment: 1
        case .authorizationHeader, .urlCredentials: 2
        case .anthropicKey: 4
        default: 3
        }
    }
}

/// 見つけた秘密 1 つ。位置は UTF-16 で数える（`NSRange` にそのまま使える）
public struct SecretFinding: Hashable, Sendable {
    public var kind: SecretKind
    public var location: Int
    public var length: Int
    /// 値の先頭のうち見せてよい長さ（`sk-ant-api03-`・`ghp_`・秘密鍵の BEGIN の行など、決まった形の部分）
    public var visiblePrefix: Int
    /// 値の末尾のうち、決まった形として見せる長さ（秘密鍵の END の行）。末尾 4 文字を見せるかは `kind.revealsTail`
    public var visibleSuffix: Int

    public init(kind: SecretKind, location: Int, length: Int, visiblePrefix: Int = 0, visibleSuffix: Int = 0) {
        self.kind = kind
        self.location = location
        self.length = length
        self.visiblePrefix = visiblePrefix
        self.visibleSuffix = visibleSuffix
    }

    public var range: NSRange { NSRange(location: location, length: length) }
    public var confidence: SecretConfidence { kind.confidence }
}

/// 秘密っぽいもの（API キー・トークン・秘密鍵・パスワードなど）を、文字列の**形式だけ**から見つける（純粋関数）。
///
/// 判定はアプリの中だけで行い、結果（`SecretFinding`）は種類と位置だけを持つ。中身をどこかへ送ることはない。
/// 見つけるもの・見逃すもの・誤判定しうるものは `.agent/conventions.md` の「秘密の判定」に書いてある。
/// 判定を変えたら `version` を上げる（既存の履歴に 1 回だけ当て直す）。`SecretDetectorTests` に陽性と陰性の例を足すこと
public enum SecretDetector {
    /// 判定の版。上げると、起動したときに既存の履歴へ 1 回だけ当て直す（`ClipStore` の meta）
    /// （2: ランダムな文字列を英単語らしさで見分けるようにした。#30）
    public static let version = 2
    /// 長い文字列は先頭だけ見る（UTF-16。数 MB のログで取り込みを遅くしないため）
    public static let scanLimit = 512 * 1024

    /// 見つけた秘密（重ならない・位置の順）
    public static func findings(in text: String) -> [SecretFinding] {
        let ns = clipped(text)
        guard ns.length >= 8 else { return [] }
        var found: [SecretFinding] = []
        found += knownFormats(in: ns)
        found += privateKeys(in: ns)
        found += headers(in: ns)
        found += urlCredentials(in: ns)
        found += assignments(in: ns)
        if let token = randomToken(in: ns) { found.append(token) }
        return resolveOverlaps(found)
    }

    /// いちばん確度の高いもの（なければ nil）
    public static func confidence(of findings: [SecretFinding]) -> SecretConfidence? {
        findings.map(\.confidence).max()
    }

    static func clipped(_ text: String) -> NSString {
        let ns = text as NSString
        guard ns.length > scanLimit else { return ns }
        // サロゲートペアの途中で切らない
        let end = ns.rangeOfComposedCharacterSequence(at: scanLimit - 1)
        return ns.substring(to: end.location) as NSString
    }

    /// 重なったものは、優先度が高い → 長い → 前にある順に残す
    static func resolveOverlaps(_ found: [SecretFinding]) -> [SecretFinding] {
        let ordered = found.sorted {
            if $0.kind.priority != $1.kind.priority { return $0.kind.priority > $1.kind.priority }
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.location < $1.location
        }
        var kept: [SecretFinding] = []
        for finding in ordered where !kept.contains(where: { NSIntersectionRange($0.range, finding.range).length > 0 })
        {
            kept.append(finding)
        }
        return kept.sorted { $0.location < $1.location }
    }

    // MARK: 既知の形式（接頭辞が決まっているもの）

    struct Format {
        let kind: SecretKind
        let regex: NSRegularExpression
        /// 本体（接頭辞の後ろ）がランダムらしいことを確かめる（`sk-` のように短い接頭辞で、英単語の並びを拾わないため）
        let bodyCheck: BodyCheck

        enum BodyCheck {
            case none
            /// 英字と数字が入り混じる
            case random
            /// 英字だけでもよい（大文字と小文字が入り混じる。Hugging Face のトークン）
            case randomLetters
        }

        init(_ kind: SecretKind, _ pattern: String, bodyCheck: BodyCheck = .none) {
            self.kind = kind
            regex = try! NSRegularExpression(pattern: pattern)
            self.bodyCheck = bodyCheck
        }
    }

    /// 前後が英数字・`_`・`-` でないこと（`task-` の中の `sk-` などを拾わない）
    static let before = #"(?<![A-Za-z0-9_\-])"#
    static let after = #"(?![A-Za-z0-9_\-])"#

    /// 第 1 グループが見せてよい接頭辞、全体が秘密の値
    static let formats: [Format] = [
        Format(.anthropicKey, before + #"(sk-ant-[a-z]{2,10}[0-9]{0,3}-)[A-Za-z0-9_\-]{20,}"# + after),
        Format(
            .openAIKey, before + #"(sk-(?:[a-z]{2,8}-)?)[A-Za-z0-9_\-]{20,}"# + after, bodyCheck: .random),
        Format(.githubToken, before + #"(gh[pousr]_)[A-Za-z0-9]{36,255}"# + after),
        Format(.githubToken, before + #"(github_pat_)[A-Za-z0-9_]{22,255}"# + after),
        Format(
            .gitlabToken, before + #"(gl(?:pat|ptt|dt|rt|cbt|oas|ft|imt|soat|agent)-)[A-Za-z0-9_\-]{20,}"# + after),
        Format(.slackToken, before + #"(xox[abposrce]-)[A-Za-z0-9\-]{10,}"# + after, bodyCheck: .random),
        Format(.slackToken, before + #"(xapp-)[A-Za-z0-9\-]{10,}"# + after, bodyCheck: .random),
        Format(.slackWebhook, #"(https://hooks\.slack\.com/(?:services|workflows|triggers)/)[A-Za-z0-9_/\-]{8,}"#),
        Format(
            .discordWebhook,
            #"(https://(?:(?:canary|ptb)\.)?discord(?:app)?\.com/api/webhooks/)[0-9]+/[A-Za-z0-9_\-]{20,}"#),
        Format(.awsAccessKey, #"(?<![A-Z0-9])((?:AKIA|ASIA|ABIA|ACCA))[A-Z0-9]{16}(?![A-Z0-9])"#),
        Format(.googleAPIKey, before + #"(AIza)[0-9A-Za-z_\-]{35}"# + after),
        Format(.googleOAuth, before + #"(GOCSPX-)[0-9A-Za-z_\-]{28}"# + after),
        Format(.googleOAuth, before + #"(ya29\.)[0-9A-Za-z_\-]{20,}"# + after),
        Format(.stripeKey, before + #"((?:sk|rk)_(?:live|test)_)[0-9A-Za-z]{10,}"# + after),
        Format(.stripeKey, before + #"(whsec_)[0-9A-Za-z]{20,}"# + after),
        Format(.npmToken, before + #"(npm_)[A-Za-z0-9]{36}"# + after),
        Format(.huggingFaceToken, before + #"(hf_)[A-Za-z0-9]{30,}"# + after, bodyCheck: .randomLetters),
        Format(.sendGridKey, before + #"(SG\.)[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}"# + after),
        Format(.jwt, before + #"(eyJ)[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"# + after),
    ]

    static func knownFormats(in ns: NSString) -> [SecretFinding] {
        var result: [SecretFinding] = []
        let whole = NSRange(location: 0, length: ns.length)
        for format in formats {
            for match in format.regex.matches(in: ns as String, range: whole) {
                let prefix = match.range(at: 1).length
                let body = ns.substring(
                    with: NSRange(location: match.range.location + prefix, length: match.range.length - prefix))
                switch format.bodyCheck {
                case .none: break
                case .random: guard looksRandom(body) else { continue }
                case .randomLetters: guard looksRandom(body, requireDigits: false) else { continue }
                }
                result.append(
                    SecretFinding(
                        kind: format.kind, location: match.range.location, length: match.range.length,
                        visiblePrefix: prefix))
            }
        }
        return result
    }

    // MARK: 秘密鍵（PEM）

    /// 公開鍵・証明書（`BEGIN PUBLIC KEY`・`BEGIN CERTIFICATE`）は秘密ではないので拾わない
    static let privateKeyPattern = try! NSRegularExpression(
        pattern:
            #"(-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----\r?\n?)[\s\S]*?(\r?\n?-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----|$)"#
    )

    static func privateKeys(in ns: NSString) -> [SecretFinding] {
        privateKeyPattern.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).compactMap {
            match in
            // 見出しだけ（中身のない BEGIN の行）は拾わない
            guard match.range.length > match.range(at: 1).length + match.range(at: 2).length + 8 else { return nil }
            return SecretFinding(
                kind: .privateKey, location: match.range.location, length: match.range.length,
                visiblePrefix: match.range(at: 1).length, visibleSuffix: match.range(at: 2).length)
        }
    }

    // MARK: 認証ヘッダー

    /// `Authorization: Bearer …`・`Authorization: Basic …`（curl の -H の中も）。第 2 グループが値
    static let authorizationPattern = try! NSRegularExpression(
        pattern:
            #"(?i)(authorization["']?\s*[:=]\s*["']?\s*(?:bearer|basic|token|bot|digest)\s+)([A-Za-z0-9._~+/\-]{8,}=*)"#
    )
    /// ラベルなしの `Bearer …`（値がランダムなときだけ）
    static let bearerPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z])(bearer\s+)([A-Za-z0-9._~+/\-]{20,}=*)"#)
    /// `X-API-Key: …`・`PRIVATE-TOKEN: …` などのヘッダー（行の途中でも。curl の -H "…" の中）
    static let apiHeaderPattern = try! NSRegularExpression(
        pattern:
            #"(?i)(?<![A-Za-z0-9\-])((?:x-[a-z0-9\-]*?)?(?:api-?key|auth-?token|access-?token|private-token|secret|token)\s*:\s*)([A-Za-z0-9._~+/\-]{8,}=*)"#
    )

    static func headers(in ns: NSString) -> [SecretFinding] {
        var result: [SecretFinding] = []
        let whole = NSRange(location: 0, length: ns.length)
        for match in authorizationPattern.matches(in: ns as String, range: whole) {
            let value = match.range(at: 2)
            guard !isPlaceholder(ns.substring(with: value)) else { continue }
            result.append(SecretFinding(kind: .authorizationHeader, location: value.location, length: value.length))
        }
        for pattern in [bearerPattern, apiHeaderPattern] {
            for match in pattern.matches(in: ns as String, range: whole) {
                let value = match.range(at: 2)
                let text = ns.substring(with: value)
                guard !isPlaceholder(text), looksRandom(text) else { continue }
                result.append(SecretFinding(kind: .authorizationHeader, location: value.location, length: value.length))
            }
        }
        return result
    }

    // MARK: URL の中のパスワード（postgres://user:pass@host）

    static let urlCredentialPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z0-9+.\-])[a-z][a-z0-9+.\-]{1,20}://[^\s/:@'"<>]+:([^\s/@'"<>]+)@"#)

    static func urlCredentials(in ns: NSString) -> [SecretFinding] {
        urlCredentialPattern.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).compactMap {
            match in
            let value = match.range(at: 1)
            let text = ns.substring(with: value)
            guard text.count >= 3, !isPlaceholder(text), !isCodeReference(text) else { return nil }
            return SecretFinding(kind: .urlCredentials, location: value.location, length: value.length)
        }
    }

    // MARK: 代入（.env・設定ファイル・JSON・URL のクエリ・CLI の引数）

    /// 名前の強さ
    enum NameStrength {
        /// パスワード（短い値も秘密）
        case password
        /// トークン・API キー・secret など
        case secret
        /// `KEY`・`stripe_key` のような汎用の「key」（値がランダムなときだけ秘密）
        case genericKey
    }

    /// 値の書き方（同じ値でも、書き方で「参照か、値そのものか」の見分け方が変わる）
    enum ValueStyle {
        /// `NAME=value`（.env・シェル。空白なしの裸の値はそのまま値）
        case env
        /// `name = value`（コード・INI・TOML。裸の値は変数の参照のことが多い）
        case spacedAssignment
        /// `name: value`（YAML・ヘッダー）
        case colon
        /// 引用符で囲んだ値（JSON・コードの文字列）
        case quoted
        /// URL のクエリ・CLI の引数
        case parameter
    }

    /// `NAME=value`・`name = "value"`・`export NAME=value`（行頭から）
    static let assignmentPattern = try! NSRegularExpression(
        pattern:
            #"(?m)^[ \t]*(?:export[ \t]+|set[ \t]+|(?:const|let|var|final|static)[ \t]+)?([A-Za-z_][A-Za-z0-9_.\-]*)([ \t]*)=([ \t]*)(?:"([^"\n]*)"|'([^'\n]*)'|([^\s"'#;]+))"#
    )
    /// `name: value`（YAML。行頭から、行末まで）
    static let colonPattern = try! NSRegularExpression(
        pattern:
            #"(?m)^[ \t]*(?:-[ \t]+)?([A-Za-z_][A-Za-z0-9_.\-]*)[ \t]*:[ \t]+(?:"([^"\n]*)"|'([^'\n]*)'|([^\s"'#,;]+))[ \t]*[,;]?[ \t]*(?:(?:#|//).*)?$"#
    )
    /// `"name": "value"`・`name = "value"`（行の途中でも。JSON・コードの引数）
    static let quotedPattern = try! NSRegularExpression(
        pattern:
            #"(?<![A-Za-z0-9_])["']?([A-Za-z_][A-Za-z0-9_.\-]*)["']?[ \t]*(?::|=|=>)[ \t]*(?:"([^"\n]*)"|'([^'\n]*)')"#)
    /// URL のクエリ（`?access_token=…&`）
    static let queryPattern = try! NSRegularExpression(pattern: #"[?&]([A-Za-z_][A-Za-z0-9_.\-]*)=([^&#\s"'<>]+)"#)
    /// CLI の引数（`--password=…`・`--api-key …`）
    static let flagPattern = try! NSRegularExpression(
        pattern:
            #"(?<![^\s])--([A-Za-z][A-Za-z0-9\-]*)(?:=|[ \t]+)(?:"([^"\n]*)"|'([^'\n]*)'|([^\s"'|;&<>]+))"#)

    static func assignments(in ns: NSString) -> [SecretFinding] {
        var result: [SecretFinding] = []
        let string = ns as String
        let whole = NSRange(location: 0, length: ns.length)

        func add(name: NSRange, value: NSRange, style: ValueStyle) {
            guard value.location != NSNotFound, value.length > 0 else { return }
            let nameText = ns.substring(with: name)
            guard let strength = nameStrength(nameText) else { return }
            let valueText = ns.substring(with: value)
            guard isPlausibleValue(valueText, strength: strength, style: style, name: nameText) else { return }
            let kind: SecretKind = strength == .password ? .passwordAssignment : .secretAssignment
            result.append(SecretFinding(kind: kind, location: value.location, length: value.length))
        }

        for match in assignmentPattern.matches(in: string, range: whole) {
            let spaced = match.range(at: 2).length > 0 || match.range(at: 3).length > 0
            if match.range(at: 4).location != NSNotFound {
                add(name: match.range(at: 1), value: match.range(at: 4), style: .quoted)
            } else if match.range(at: 5).location != NSNotFound {
                add(name: match.range(at: 1), value: match.range(at: 5), style: .quoted)
            } else {
                add(name: match.range(at: 1), value: match.range(at: 6), style: spaced ? .spacedAssignment : .env)
            }
        }
        for match in colonPattern.matches(in: string, range: whole) {
            let quoted = [2, 3].map { match.range(at: $0) }.first { $0.location != NSNotFound }
            add(name: match.range(at: 1), value: quoted ?? match.range(at: 4), style: quoted == nil ? .colon : .quoted)
        }
        for match in quotedPattern.matches(in: string, range: whole) {
            let value = [2, 3].map { match.range(at: $0) }.first { $0.location != NSNotFound }
            if let value { add(name: match.range(at: 1), value: value, style: .quoted) }
        }
        for match in queryPattern.matches(in: string, range: whole) {
            add(name: match.range(at: 1), value: match.range(at: 2), style: .parameter)
        }
        for match in flagPattern.matches(in: string, range: whole) {
            let value = [2, 3, 4].map { match.range(at: $0) }.first { $0.location != NSNotFound }
            if let value { add(name: match.range(at: 1), value: value, style: .parameter) }
        }
        return result
    }

    /// 名前を小文字の語に分ける（`OPENAI_API_KEY`・`apiKey`・`x-api-key` → ["openai", "api", "key"]）
    static func nameSegments(_ name: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if character == "_" || character == "-" || character == "." {
                if !current.isEmpty { segments.append(current) }
                current = ""
            } else {
                // camelCase の切れ目（小文字・数字 → 大文字）
                if character.isUppercase, let previous, previous.isLowercase || previous.isNumber, !current.isEmpty {
                    segments.append(current)
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { segments.append(current) }
        return segments.map { $0.lowercased() }
    }

    static let passwordWords: Set<String> = ["password", "passwd", "pwd", "pass", "passphrase", "passcode"]
    static let secretWords: Set<String> = [
        "secret", "secrets", "token", "apikey", "credential", "credentials", "privatekey", "accesskey", "secretkey",
    ]
    /// 「key」の前にあると秘密の鍵になる語
    static let keyQualifiers: Set<String> = [
        "api", "access", "secret", "private", "auth", "signing", "encryption", "master", "app", "license", "service",
        "account", "admin", "session", "client", "hmac", "jwt", "crypto", "webhook", "server", "consumer",
        "subscription", "deploy", "openai", "anthropic", "stripe", "github", "gemini", "google", "aws", "azure",
        "sendgrid", "mailgun", "twilio", "slack", "discord", "supabase", "firebase", "vercel", "cloudflare",
    ]
    /// 「key」の前にあると秘密でない語（並べ替えのキー・キャッシュのキーなど）
    static let nonSecretKeyQualifiers: Set<String> = [
        "sort", "cache", "partition", "primary", "foreign", "hash", "map", "dict", "object", "registry", "table",
        "lookup", "group", "route", "sequence", "unique", "idempotency", "composite", "list", "item", "row",
        "column", "index", "cursor", "storage", "bucket", "public", "publishable", "anon", "react", "shortcut",
        "hot", "translation", "i18n", "locale", "message", "cell", "dictionary", "user", "store", "state",
    ]
    /// 「token」の前にあると秘密でない語（ページ送りのトークン・機械学習の特別な語など）
    static let nonSecretTokenQualifiers: Set<String> = [
        "page", "next", "prev", "previous", "continuation", "sync", "cursor", "pagination", "completion", "prompt",
        "input", "output", "stop", "special", "eos", "bos", "pad", "unk", "sep", "cls", "mask", "cancellation",
        "cancel", "change", "resume", "delta", "request", "dedup", "max", "total",
    ]
    /// 最後の語がこれなら、秘密の値ではなく付随情報（`TOKEN_LIMIT`・`PASSWORD_MIN_LENGTH`・`API_KEY_PATH` など）
    static let excludedLastWords: Set<String> = [
        "id", "ids", "name", "names", "path", "paths", "file", "files", "dir", "uri", "url", "type", "types", "size",
        "length", "len", "count", "limit", "limits", "max", "min", "ttl", "timeout", "expiry", "expires",
        "expiration", "at", "header", "headers", "field", "fields", "prefix", "suffix", "format", "mode",
        "enabled", "enable", "disabled", "required", "index", "version", "hint", "label", "placeholder", "policy",
        "rule", "rules", "regex", "pattern", "env", "var", "variable", "location", "endpoint", "host", "port",
        "flag", "list", "provider", "manager", "store", "storage", "helper", "kind", "strategy", "scope", "scopes",
        "algorithm", "alg", "method", "input", "prompt", "request", "response", "error", "errors", "message",
        "text", "title", "description", "icon", "button", "hash", "salt", "rotation", "expired", "valid", "visible",
        "reset", "confirm", "confirmation", "strength", "lifetime", "tokens", "used", "usage", "budget",
    ]
    /// 最後の語がこれなら、その前の語で決める（`SECRET_KEY_BASE`・`token_value`）
    static let transparentLastWords: Set<String> = [
        "base", "value", "string", "str", "data", "raw", "plain", "b64", "base64", "hex",
    ]
    /// どこかにあれば秘密でない（公開してよい鍵）
    static let publicWords: Set<String> = ["public", "publishable", "pub", "anon"]

    static func nameStrength(_ name: String) -> NameStrength? {
        var segments = nameSegments(name)
        guard !segments.isEmpty, segments.allSatisfy({ !publicWords.contains($0) }) else { return nil }
        // `GITHUB_TOKEN_2`・`SECRET_KEY_BASE` は、その前の語で決める
        while segments.count > 1, let last = segments.last,
            transparentLastWords.contains(last) || last.allSatisfy(\.isNumber)
        {
            segments.removeLast()
        }
        guard let last = segments.last, !excludedLastWords.contains(last) else { return nil }
        let previous = segments.count > 1 ? segments[segments.count - 2] : nil
        if passwordWords.contains(last) { return .password }
        if secretWords.contains(last) {
            if last == "token", let previous, nonSecretTokenQualifiers.contains(previous) { return nil }
            return .secret
        }
        guard last == "key" else { return nil }
        if let previous, nonSecretKeyQualifiers.contains(previous) { return nil }
        if let previous, keyQualifiers.contains(previous) { return .secret }
        return .genericKey
    }

    /// プレースホルダ・例として書かれた値（`your-api-key`・`<token>`・`${TOKEN}`・`xxxx`・`changeme`）
    static func isPlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        if placeholderWords.contains(lower) { return true }
        for fragment in placeholderFragments where lower.contains(fragment) { return true }
        if let first = value.first, let last = value.last {
            if (first == "<" && last == ">") || (first == "[" && last == "]") || (first == "{" && last == "}") {
                return true
            }
            if first == "%" && last == "%" { return true }
        }
        // 同じ文字の繰り返し（`********`・`xxxxxxxx`・`••••`・`00000000`）
        if let first = value.first, value.allSatisfy({ $0 == first }) { return true }
        return false
    }

    static let placeholderWords: Set<String> = [
        "password", "passwd", "pass", "secret", "token", "apikey", "api_key", "api-key", "key", "changeme",
        "change_me", "change-me", "example", "sample", "test", "dummy", "placeholder", "required", "optional",
        "null", "nil", "none", "undefined", "true", "false", "yes", "no", "on", "off", "empty", "default",
        "string", "str", "number", "int", "integer", "bool", "boolean", "any", "unknown", "object", "bytes",
        "float", "double", "char", "void", "never", "text", "varchar", "uuid", "env", "redacted", "hidden",
        "masked", "secret_key", "access_token", "bearer", "basic", "foo", "bar", "baz", "hoge", "fuga", "piyo",
        "todo", "tbd", "fixme", "xxx", "abc", "abc123", "123456", "12345678", "password123", "admin", "root",
        "user", "username", "letmein", "qwerty",
    ]
    static let placeholderFragments = [
        "your", "here", "xxxx", "****", "example", "placeholder", "changeme", "change_me", "change-me", "replace",
        "insert", "dummy", "sample", "redacted", "<", ">", "${", "{{", "$(", "•", "…", "...",
    ]

    /// 値ではなく、変数・関数・設定の参照（`os.environ["X"]`・`process.env.TOKEN`・`getToken()`・`$TOKEN`）
    static func isCodeReference(_ value: String) -> Bool {
        if value.hasPrefix("$") || value.hasPrefix("%") || value.hasPrefix("@") { return true }
        if value.contains(where: { "()[]{}<>`\\".contains($0) }) { return true }
        // ドットでつないだ識別子（`settings.SECRET_KEY`・`config.apiKey`）
        if value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil
        {
            return true
        }
        return false
    }

    /// 型の名前らしい（`String`・`Token`・`UserSecret`）
    static func isTypeName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "?!"))
        return trimmed.range(of: #"^(?:[A-Z][a-z]+)+[0-9]{0,2}$"#, options: .regularExpression) != nil
    }

    /// 環境変数の名前らしい（`OPENAI_API_KEY=ANTHROPIC_API_KEY` のような参照）
    static func isEnvName(_ value: String) -> Bool {
        value.range(of: #"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$"#, options: .regularExpression) != nil
    }

    static func isPlausibleValue(_ value: String, strength: NameStrength, style: ValueStyle, name: String) -> Bool {
        let minimum = strength == .password ? 4 : 8
        guard value.utf16.count >= minimum, value.utf16.count <= 4096 else { return false }
        // 空白・ASCII 以外を含むものは文章（「パスワードを入力」のような画面の文言）
        guard value.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return false }
        guard !isPlaceholder(value), !isCodeReference(value), !isTypeName(value), !isEnvName(value) else {
            return false
        }
        // 汎用の「key」は値がランダムなときだけ
        if strength == .genericKey { return value.utf16.count >= 16 && looksRandom(value) }
        let identifierLike = value.range(of: #"^[A-Za-z_]+$"#, options: .regularExpression) != nil
        switch style {
        case .env, .quoted, .parameter:
            return true
        case .spacedAssignment:
            // `token = token_from_env` のような変数の参照を拾わない
            return !identifierLike
        case .colon:
            // YAML の裸の値は、環境変数の名前（大文字）の項目か、数字・記号を含むものだけ（`token: bearer` などを拾わない）
            return !identifierLike || isEnvName(name) || name == name.uppercased()
        }
    }

    // MARK: ランダムな文字列（形式から外れるもの・確度は中）

    /// 文字列全体が 1 語のときだけ見る（文章の中のランダムな語は拾わない）
    static func randomToken(in ns: NSString) -> SecretFinding? {
        let text = (ns as String).trimmingCharacters(in: .whitespacesAndNewlines)
        let length = text.utf16.count
        guard (20...512).contains(length), !text.contains(where: { $0.isWhitespace }) else { return nil }
        guard text.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }) else { return nil }
        guard !isHex(text), !isUUIDLike(text), !isULID(text), !isEncodedNonSecret(text), !isPlaceholder(text),
            !isCodeReference(text), !text.contains(".."), !publicPrefixes.contains(where: { text.hasPrefix($0) }),
            !hasFileExtension(text)
        else { return nil }
        guard looksLikeRandomToken(text), hasMixedCase(text) else { return nil }
        let start = (ns as String as NSString).range(of: text).location
        guard start != NSNotFound else { return nil }
        return SecretFinding(kind: .randomToken, location: start, length: length)
    }

    /// 末尾が「.拡張子」のもの（`Screenshot_2024-11-02_144456.png`・`Tcl_AsyncCreate.3tcl`）はファイル名として拾わない
    static func hasFileExtension(_ text: String) -> Bool {
        text.range(of: #"\.[A-Za-z0-9]{1,10}$"#, options: .regularExpression) != nil
    }

    /// 確度「中」のランダムな文字列らしいか（#30）。文字の種類（大文字・小文字・数字・記号）の切り替わりが 3 割以上・
    /// エントロピーが十分・英単語の並び（`isWordLike`）でないこと。
    ///
    /// 既知の形式の本体などに使う `looksRandom` より広い（数字を求めない・英字の連続の長さで外さない）。
    /// 乱数のトークンは、20 文字だと数字が 0〜1 個のことや、同じ大きさの英字がたまたま長く続くことがよくあり、
    /// `looksRandom` では 2 割近く見逃していた。広げた分は確度「中」（伏せるだけで消さない）にしか入らない
    static func looksLikeRandomToken(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        guard scalars.count >= 8, letters >= 4 else { return false }
        let categories = scalars.map(characterCategory)
        var transitions = 0
        for index in 1..<categories.count where categories[index] != categories[index - 1] { transitions += 1 }
        guard Double(transitions) / Double(scalars.count - 1) >= 0.3 else { return false }
        guard entropy(scalars) >= min(3.0, log2(Double(scalars.count)) * 0.8) else { return false }
        return !isWordLike(scalars, categories: categories)
    }

    /// 0: 数字・1: 大文字・2: 小文字・3: そのほか
    static func characterCategory(_ scalar: Unicode.Scalar) -> Int {
        if CharacterSet.decimalDigits.contains(scalar) { return 0 }
        if CharacterSet.uppercaseLetters.contains(scalar) { return 1 }
        if CharacterSet.lowercaseLetters.contains(scalar) { return 2 }
        return 3
    }

    /// 英単語をつないだもの（識別子・ファイル名・文）らしいか。
    ///
    /// 隣り合う英字の 2 文字（大文字小文字を区別しない）が「英語でよく出る並び」（`commonBigrams`・676 通りのうち 200 個）に
    /// 入るかを数え、乱数（1 対あたり 200/676 の確率で入る）と英単語（1 対あたり 0.8）のどちらに近いかを尤度比で比べる。
    /// 英単語の方が e^3.5（約 33 倍）より確からしければ英単語らしい。長いほど証拠が増えるので、乱数を英単語と取り違える割合も、
    /// 英単語を乱数と取り違える割合も下がる（「期待 + 3 標準偏差」のように固定の幅で切ると、長さによらず乱数の約 1% を取り違え、
    /// 64 文字では直す前より見逃しが増えた。#30 の計測）。
    /// 全部の英字の対と、同じ大きさどうしの対（`getURLForKey` の `ge`・`et`・`or` のような語の中の対）の両方で見て、
    /// どちらかで英単語らしければ英単語とする（`kMMCCmd_MODE_SELECT_10` のような大文字の語は、語の中の対で見つかる）
    static func isWordLike(_ scalars: [Unicode.Scalar], categories: [Int]) -> Bool {
        var all = (pairs: 0, hits: 0)
        var same = (pairs: 0, hits: 0)
        for index in 1..<scalars.count {
            let previous = categories[index - 1]
            let current = categories[index]
            guard previous == 1 || previous == 2, current == 1 || current == 2,
                let first = asciiLetterIndex(scalars[index - 1]), let second = asciiLetterIndex(scalars[index])
            else { continue }
            let common = commonBigrams[first * 26 + second] ? 1 : 0
            all.pairs += 1
            all.hits += common
            if previous == current {
                same.pairs += 1
                same.hits += common
            }
        }
        return wordLikeScore(hits: all.hits, pairs: all.pairs) > wordLikeThreshold
            || wordLikeScore(hits: same.hits, pairs: same.pairs) > wordLikeThreshold
    }

    /// 英単語の対がよく出る並びに入る確率（`/usr/share/dict/words` の語では 0.9。識別子は略語が混じるので少し低く見る）
    static let wordBigramProbability = 0.8
    /// 対数尤度比の基準（e^3.5 ≈ 33 倍）。#30 の計測（`scripts/secret-bench.sh`）で、誤判定がどの種類でも増えず、
    /// 見逃しがどの長さでも減るか変わらない値として選んだ
    static let wordLikeThreshold = 3.5

    /// 英単語と乱数の対数尤度比（`hits` 個がよく出る並びで、`pairs - hits` 個がそうでない）
    static func wordLikeScore(hits: Int, pairs: Int) -> Double {
        let random = commonBigramProbability
        let word = wordBigramProbability
        return Double(hits) * log(word / random) + Double(pairs - hits) * log((1 - word) / (1 - random))
    }

    /// `a`〜`z`・`A`〜`Z` を 0〜25 に（それ以外は nil）
    static func asciiLetterIndex(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x41...0x5A: Int(scalar.value - 0x41)
        case 0x61...0x7A: Int(scalar.value - 0x61)
        default: nil
        }
    }

    /// 英語でよく出る 2 文字の並び。macOS の `/usr/share/dict/words`（Webster's Second・23 万語）で数えた上位 200 個
    /// （200 番目と 201 番目は回数が違うので、数え直しても同じになる。`SecretDetectorBench` が数え直して照らす）
    static let commonBigramList = """
        ab ac ad ae ag ai al am an ap ar as at au ba be bi bl bo br bu ca ce ch ci ck cl co cr ct cu cy da de di do dr \
        ea ec ed ee ef eg ei el em en eo ep er es et eu ex fe fi fl fo fu ga ge gi gl go gr gu ha he hi ho hr hy ia ib \
        ic id ie if ig il im in io ip ir is it iv iz ke ki la le li ll lo lt lu ly ma mb me mi mo mp mu my na nc nd ne \
        ng ni nn no ns nt oa ob oc od og oi ol om on oo op or os ot ou ov ow pa pe ph pi pl po pr pt pu qu ra rc rd re \
        ri rm rn ro rp rr rs rt ru ry sa sc se sh si sl sm so sp ss st su ta te th ti to tr tt tu ty ua ub uc ud ui ul \
        um un up ur us ut va ve vi wa wi yl yp ys ze
        """
    static let commonBigramCount = commonBigramList.split(separator: " ").count
    /// `commonBigramList` を 26 × 26 の表に（`first * 26 + second`）
    static let commonBigrams: [Bool] = {
        var table = [Bool](repeating: false, count: 676)
        for pair in commonBigramList.split(separator: " ") {
            let letters = pair.unicodeScalars.compactMap(asciiLetterIndex)
            if letters.count == 2 { table[letters[0] * 26 + letters[1]] = true }
        }
        return table
    }()
    /// 乱数の英字の対が、よく出る並びに入る確率（200/676）
    static let commonBigramProbability = Double(commonBigramCount) / 676

    /// 公開してよい鍵の接頭辞（Stripe の publishable key）
    static let publicPrefixes = ["pk_live_", "pk_test_"]

    static let tokenCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-.~")

    /// 16 進だけ（git のハッシュ・SHA-256・MD5・ObjectId）
    static func isHex(_ text: String) -> Bool {
        let body = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return body.allSatisfy(\.isHexDigit) || body.replacingOccurrences(of: "-", with: "").allSatisfy(\.isHexDigit)
    }

    /// UUID（区切りあり・なし）
    static func isUUIDLike(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
            || text.range(
                of: #"^[0-9A-Fa-f]{8}-?[0-9A-Fa-f]{4}-?[0-9A-Fa-f]{4}-?[0-9A-Fa-f]{4}-?[0-9A-Fa-f]{12}$"#,
                options: .regularExpression) != nil
    }

    /// ULID（Crockford の base32 で 26 文字・大文字）
    static func isULID(_ text: String) -> Bool {
        text.range(of: #"^[0-7][0-9A-HJKMNP-TV-Z]{25}$"#, options: .regularExpression) != nil
    }

    /// Base64 で、画像・PDF・圧縮ファイルなどの中身か、ふつうの文章を符号化したもの（秘密ではない）
    static func isEncodedNonSecret(_ text: String) -> Bool {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let usable = base64.utf8.count / 4 * 4
        guard usable >= 8 else { return false }
        base64 = String(base64.prefix(usable))
        guard let data = Data(base64Encoded: base64) else { return false }
        let bytes = [UInt8](data)
        let magics: [[UInt8]] = [
            [0x89, 0x50, 0x4E, 0x47],  // PNG
            [0x47, 0x49, 0x46, 0x38],  // GIF
            [0xFF, 0xD8, 0xFF],  // JPEG
            [0x25, 0x50, 0x44, 0x46],  // PDF
            [0x52, 0x49, 0x46, 0x46],  // RIFF（WebP・WAV）
            [0x50, 0x4B, 0x03, 0x04],  // ZIP
            [0x1F, 0x8B],  // gzip
            [0x00, 0x00, 0x01, 0x00],  // ICO
            [0x42, 0x4D],  // BMP
            [0x49, 0x49, 0x2A, 0x00], [0x4D, 0x4D, 0x00, 0x2A],  // TIFF
        ]
        if magics.contains(where: { bytes.starts(with: $0) }) { return true }
        // 文章（印字できる ASCII と空白がほとんど）を符号化したもの
        let printable = bytes.filter { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }.count
        return bytes.count >= 6 && Double(printable) / Double(bytes.count) > 0.95 && bytes.contains(0x20)
    }

    static func hasMixedCase(_ text: String) -> Bool {
        text.contains(where: \.isUppercase) && text.contains(where: \.isLowercase)
    }

    /// ランダムらしいか。文字の種類（大文字・小文字・数字・記号）の切り替わりの多さ、英単語らしい並びの少なさ、
    /// 文字のばらつき（エントロピー）で見る。
    ///
    /// 乱数の英数字（62 種）なら、隣どうしの文字の種類が変わる割合は約 0.6、同じ大きさの英字が 5 文字以上続く部分は 1 割未満。
    /// `base64EncodedStringWithOptions2` のような識別子は、切り替わりが 0.3 前後で、5 文字以上の英字の並びが半分を超える。
    /// ふつうは数字を 2 つ以上含むことも求める（英単語をつないだ名前を外すため）
    public static func looksRandom(_ text: String, requireDigits: Bool = true) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 8 else { return false }
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        guard digits >= (requireDigits ? 2 : 0), letters >= 4 else { return false }
        func category(_ scalar: Unicode.Scalar) -> Int {
            if CharacterSet.decimalDigits.contains(scalar) { return 0 }
            if CharacterSet.uppercaseLetters.contains(scalar) { return 1 }
            if CharacterSet.lowercaseLetters.contains(scalar) { return 2 }
            return 3
        }
        var transitions = 0
        for index in 1..<scalars.count where category(scalars[index]) != category(scalars[index - 1]) {
            transitions += 1
        }
        let ratio = Double(transitions) / Double(scalars.count - 1)
        guard ratio >= 0.3 else { return false }
        // 英単語らしい並び（同じ大きさの英字が 5 文字以上続く部分）の割合。英字だけの値（Hugging Face）は大文字と小文字が半々なので緩める
        var wordLike = 0
        var run = 1
        for index in 1...scalars.count {
            if index < scalars.count, category(scalars[index]) == category(scalars[index - 1]),
                category(scalars[index]) == 1 || category(scalars[index]) == 2
            {
                run += 1
                continue
            }
            if run >= 5 { wordLike += run }
            run = 1
        }
        guard Double(wordLike) / Double(scalars.count) <= (requireDigits ? 0.35 : 0.5) else { return false }
        // 同じ文字ばかり（`XXXXXXXXXXXX0000`）を外す。短い値は取りうるエントロピーも小さいので、長さに合わせて緩める
        return entropy(scalars) >= min(3.0, log2(Double(scalars.count)) * 0.8)
    }

    /// 1 文字あたりのシャノンエントロピー（ビット）
    static func entropy(_ scalars: [Unicode.Scalar]) -> Double {
        var counts: [Unicode.Scalar: Int] = [:]
        for scalar in scalars { counts[scalar, default: 0] += 1 }
        let total = Double(scalars.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }
}
