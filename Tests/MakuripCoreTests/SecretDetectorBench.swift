import CryptoKit
import Foundation
import Testing

@testable import MakuripCore

/// 秘密の判定の「見逃し」と「誤判定」を数える計測（#30）。`MAKURIP_SECRET_BENCH=1` のときだけ動く（`scripts/secret-bench.sh`）。
///
/// - 見逃し: 本物の乱数トークン（種を決めた擬似乱数。長さと文字の種類ごと）に、何も見つけなかった割合
/// - 誤判定: 秘密でない文字列に何か見つけた割合。合成したもの（UUID・ハッシュ・Base64 の画像など）と、
///   Mac の SDK のヘッダー（識別子・コメントの英文・URL・コードの行）・SDK のファイル名・このリポジトリの文書（日本語）と Swift の行
///
/// 出すのは件数と割合だけ。`MAKURIP_SECRET_BENCH_SHOW=<誤判定の種類名>` を付けると、その種類の誤判定の例
/// （秘密でない公開の文字列だけ）を出す。乱数トークンの値は出さない
@Suite("秘密の判定の計測（見逃しと誤判定）")
struct SecretDetectorBench {
    static let environment = ProcessInfo.processInfo.environment

    @Test("見逃しと誤判定の割合")
    func measure() throws {
        guard Self.environment["MAKURIP_SECRET_BENCH"] == "1" else { return }
        let show = Self.environment["MAKURIP_SECRET_BENCH_SHOW"]
        print("BENCH|見逃し|文字の種類|長さ|見逃した|件数|割合|確度「高」")
        for (name, alphabet) in BenchCorpus.tokenAlphabets {
            for length in [20, 24, 32, 40, 64] {
                let tokens = BenchCorpus.randomTokens(alphabet: alphabet, length: length, count: 5000)
                var missed = 0
                var high = 0
                for token in tokens {
                    let findings = SecretDetector.findings(in: token)
                    if findings.isEmpty { missed += 1 }
                    if SecretDetector.confidence(of: findings) == .high { high += 1 }
                }
                print(
                    "BENCH|見逃し|\(name)|\(length)|\(missed)|\(tokens.count)|\(Self.percent(missed, tokens.count))|\(high)"
                )
            }
        }
        print("BENCH|誤判定|種類|誤判定|件数|割合|当たった判定")
        var totalWrong = 0
        var total = 0
        for (name, texts) in BenchCorpus.negatives() {
            var wrong = 0
            var kinds: [String: Int] = [:]
            var examples: [String] = []
            for text in texts {
                let findings = SecretDetector.findings(in: text)
                guard !findings.isEmpty else { continue }
                wrong += 1
                for kind in Set(findings.map(\.kind)) { kinds["\(kind)", default: 0] += 1 }
                if show == name, examples.count < 60 { examples.append(String(text.prefix(120))) }
            }
            totalWrong += wrong
            total += texts.count
            let breakdown = kinds.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            print("BENCH|誤判定|\(name)|\(wrong)|\(texts.count)|\(Self.percent(wrong, texts.count))|\(breakdown)")
            for example in examples { print("BENCH-EXAMPLE|\(name)|\(example)") }
        }
        print("BENCH|誤判定|合計|\(totalWrong)|\(total)|\(Self.percent(totalWrong, total))|")
        // 判定器に埋め込んだ「英語でよく出る並び」が、辞書から数え直した上位 200 個と同じか
        let recounted = Self.commonBigramsFromDictionary()
        let embedded = Set(SecretDetector.commonBigramList.split(separator: " ").map(String.init))
        print("BENCH|よく出る並び|辞書から数え直した上位 \(recounted.count) 個と一致|\(recounted == embedded ? "yes" : "no")")
        #expect(recounted == embedded)
    }

    /// `/usr/share/dict/words` の英字だけの語で、隣り合う 2 文字（小文字）を数えた上位 200 個（回数が同じなら並びの順）
    static func commonBigramsFromDictionary() -> Set<String> {
        var counts: [String: Int] = [:]
        let text = (try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)) ?? ""
        for word in text.split(separator: "\n") {
            let letters = Array(word.lowercased())
            guard letters.count >= 2, letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            for index in 1..<letters.count { counts[String([letters[index - 1], letters[index]]), default: 0] += 1 }
        }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return Set(ranked.prefix(200).map(\.key))
    }

    static func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "-" : String(format: "%.2f%%", Double(part) * 100 / Double(whole))
    }
}

/// 計測に使う文字列の集まり。どれも公開されているもの（SDK・このリポジトリ）か、種を決めて作ったもの
enum BenchCorpus {
    /// 種を決めた擬似乱数（SplitMix64）
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    static let lower = "abcdefghijklmnopqrstuvwxyz"
    static let digits = "0123456789"

    /// 乱数トークンの文字の種類。上の 3 つが確度「中」で拾いたいもの。下の 2 つは拾わない方針のもの（参考）
    static let tokenAlphabets: [(String, [Character])] = [
        ("英数字", Array(upper + lower + digits)),
        ("英数字と -_", Array(upper + lower + digits + "-_")),
        ("英数字と +/", Array(upper + lower + digits + "+/")),
        ("（参考）英字だけ", Array(upper + lower)),
        ("（参考）小文字と数字", Array(lower + digits)),
    ]

    static func randomTokens(alphabet: [Character], length: Int, count: Int) -> [String] {
        var generator = Generator(state: UInt64(length) &* 1_000_003 &+ UInt64(alphabet.count))
        return (0..<count).map { _ in String((0..<length).map { _ in alphabet.randomElement(using: &generator)! }) }
    }

    static func hex(_ count: Int, using generator: inout Generator, upper: Bool = false) -> String {
        let characters = Array(upper ? "0123456789ABCDEF" : "0123456789abcdef")
        return String((0..<count).map { _ in characters.randomElement(using: &generator)! })
    }

    static func bytes(_ count: Int, using generator: inout Generator) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// 1 種類あたりの上限（決まった並びに混ぜてから先頭を取る）
    static let limit = 20000

    static func sample(_ texts: Set<String>, seed: UInt64) -> [String] {
        var generator = Generator(state: seed)
        return Array(texts.sorted().shuffled(using: &generator).prefix(limit))
    }

    /// 秘密でない文字列の集まり（種類の名前と中身）
    static func negatives() -> [(String, [String])] {
        var result = synthetic()
        let environment = SecretDetectorBench.environment
        if let sdk = environment["MAKURIP_SECRET_BENCH_SDK"] {
            let headers = sdkHeaders(sdk)
            result.append(("識別子（SDK）", sample(headers.identifiers, seed: 101)))
            result.append(("英文（SDK のコメント）", sample(headers.english, seed: 102)))
            result.append(("URL（SDK のコメント）", sample(headers.urls, seed: 103)))
            result.append(("URL のパス（SDK のコメント）", sample(headers.paths, seed: 104)))
            result.append(("コードの行（SDK のヘッダー）", sample(headers.code, seed: 105)))
            result.append(("ファイル名（SDK）", sample(fileNames(sdk), seed: 106)))
        }
        if let repo = environment["MAKURIP_SECRET_BENCH_REPO"] {
            let texts = repoTexts(repo)
            result.append(("日本語の文（このリポジトリの文書）", sample(texts.japanese, seed: 107)))
            result.append(("コードの行（このリポジトリの Swift）", sample(texts.swift, seed: 108)))
            result.append(("識別子（このリポジトリの Swift）", sample(texts.identifiers, seed: 109)))
        }
        return result
    }

    static func synthetic() -> [(String, [String])] {
        var generator = Generator(state: 7)
        let count = 2000
        func make(_ body: (inout Generator) -> String) -> [String] { (0..<count).map { _ in body(&generator) } }
        let words = ["image", "photo", "report", "final", "draft", "notes", "backup", "export", "build", "release"]
        return [
            ("UUID", make { _ in UUID().uuidString } + make { _ in UUID().uuidString.lowercased() }),
            ("UUID（区切りなし）", make { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }),
            ("git のハッシュ", make { hex(40, using: &$0) } + make { hex(Int.random(in: 7...12, using: &$0), using: &$0) }),
            (
                "SHA-256・MD5・SHA-1",
                make { hex(64, using: &$0) } + make { hex(32, using: &$0) }
                    + make { hex(40, using: &$0, upper: true) }
            ),
            (
                "Base64 の画像（PNG・JPEG・GIF・PDF）",
                make { generator in
                    let heads: [[UInt8]] = [
                        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], [0xFF, 0xD8, 0xFF, 0xE0],
                        [0x47, 0x49, 0x46, 0x38, 0x39, 0x61], [0x25, 0x50, 0x44, 0x46, 0x2D],
                    ]
                    let head = heads.randomElement(using: &generator)!
                    let body = bytes(Int.random(in: 12...300, using: &generator), using: &generator)
                    return Data(head + body).base64EncodedString()
                }
            ),
            (
                "Base64 の文章",
                make { generator in
                    let sentence = (0..<Int.random(in: 4...12, using: &generator)).map { _ in
                        words.randomElement(using: &generator)!
                    }.joined(separator: " ")
                    return Data(sentence.utf8).base64EncodedString()
                }
            ),
            (
                "ULID",
                make { generator in
                    let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
                    return "0" + String((0..<25).map { _ in crockford.randomElement(using: &generator)! })
                }
            ),
            (
                "日時・版",
                make { generator in
                    let n = [2000...2030, 1...12, 1...28, 0...23, 0...59, 0...59, 0...999].map {
                        Int.random(in: $0, using: &generator)
                    }
                    return String(
                        format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", n[0], n[1], n[2], n[3], n[4], n[5], n[6])
                }
                    + make { generator in
                        let n = [0...20, 0...40, 0...99, 1...9, 100...99999].map {
                            Int.random(in: $0, using: &generator)
                        }
                        return "v\(n[0]).\(n[1]).\(n[2])-beta.\(n[3])+build.\(n[4])"
                    }
            ),
            (
                "ファイル名（合成）",
                make { generator in
                    let n = [2015...2030, 1...12, 1...28, 100000...235959, 10...23, 10...59, 10...59, 1...9].map {
                        Int.random(in: $0, using: &generator)
                    }
                    let word = words.randomElement(using: &generator)!
                    return [
                        "IMG_\(n[0])\(String(format: "%02d%02d", n[1], n[2]))_\(n[3]).jpg",
                        "Screenshot_\(n[0])-\(String(format: "%02d", n[1]))-\(String(format: "%02d", n[2]))_\(n[4])\(n[5])\(n[6]).png",
                        "\(word)_\(word.capitalized)Final_v\(n[7])_\(n[0]).pdf",
                    ].randomElement(using: &generator)!
                }
            ),
        ]
    }

    // MARK: SDK

    struct HeaderTexts {
        var identifiers: Set<String> = []
        var english: Set<String> = []
        var urls: Set<String> = []
        var paths: Set<String> = []
        var code: Set<String> = []
    }

    static let identifierPattern = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]{11,}"#)
    static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s"'<>()\[\]]+"#)

    static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }

    static func sdkHeaders(_ sdk: String) -> HeaderTexts {
        var texts = HeaderTexts()
        let root = sdk + "/System/Library/Frameworks"
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return texts }
        var seen: Set<String> = []
        for case let path as String in enumerator where path.hasSuffix(".h") && path.contains("/Headers/") {
            // 同じヘッダーが Versions/A と Headers の両方から見えることがある
            let key = (path as NSString).lastPathComponent + "|" + path.components(separatedBy: ".framework").first!
            guard seen.insert(key).inserted,
                let data = FileManager.default.contents(atPath: root + "/" + path)
            else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 8 else { continue }
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    let body = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/*! \t"))
                    if body.split(separator: " ").count >= 4 { texts.english.insert(body) }
                    for url in matches(urlPattern, in: body) {
                        texts.urls.insert(url)
                        if let path = URL(string: url)?.path, path.count > 1 { texts.paths.insert(path) }
                    }
                } else {
                    texts.code.insert(trimmed)
                }
                for identifier in matches(identifierPattern, in: trimmed) { texts.identifiers.insert(identifier) }
            }
        }
        return texts
    }

    static func fileNames(_ sdk: String) -> Set<String> {
        var names: Set<String> = []
        guard let enumerator = FileManager.default.enumerator(atPath: sdk) else { return names }
        for case let path as String in enumerator {
            let name = (path as NSString).lastPathComponent
            if name.count >= 8 { names.insert(name) }
        }
        return names
    }

    // MARK: このリポジトリ

    static func repoTexts(_ repo: String) -> (japanese: Set<String>, swift: Set<String>, identifiers: Set<String>) {
        var japanese: Set<String> = []
        var swift: Set<String> = []
        var identifiers: Set<String> = []
        // Tests/ には、わざと秘密に似せた文字列があるので入れない
        let skip = [".build", ".app-build", ".git", ".e2e", ".ui-compare", "node_modules", "Tests"]
        guard let enumerator = FileManager.default.enumerator(atPath: repo) else { return ([], [], []) }
        for case let path as String in enumerator {
            if skip.contains(where: { path.hasPrefix($0) }) {
                enumerator.skipDescendants()
                continue
            }
            let isMarkdown = path.hasSuffix(".md")
            let isSwift = path.hasSuffix(".swift")
            guard isMarkdown || isSwift, let data = FileManager.default.contents(atPath: repo + "/" + path) else {
                continue
            }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 8 else { continue }
                if isMarkdown, trimmed.unicodeScalars.contains(where: { (0x3040...0x9FFF).contains($0.value) }) {
                    japanese.insert(trimmed)
                }
                if isSwift {
                    swift.insert(trimmed)
                    for identifier in matches(identifierPattern, in: trimmed) { identifiers.insert(identifier) }
                }
            }
        }
        return (japanese, swift, identifiers)
    }
}
