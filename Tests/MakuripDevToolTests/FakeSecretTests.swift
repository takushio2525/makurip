import Foundation
import Testing

@testable import MakuripCore
@testable import MakuripDevTool

/// 種を決めた擬似乱数（SplitMix64）。偽の秘密を決まった並びで何通りも作って確かめるため
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// E2E の偽の秘密（`MakuripDevTool pb-write secret-*`）が、判定の条件を必ず満たすこと（#21: 一様な乱数で約 0.7% が外れていた）。
/// 偽物でも値は出力しない: `#expect` には判定の結果（真偽・種類・件数）だけを渡す（値を渡すと、落ちたときに展開して表示される）
@Suite("E2E の偽の秘密（fakeSecretBody）")
struct FakeSecretTests {
    static let seeds: Range<UInt64> = 0..<500

    static func body(_ count: Int, seed: UInt64) -> String {
        var generator = SeededGenerator(state: seed)
        return fakeSecretBody(count, using: &generator)
    }

    static func kinds(_ text: String) -> [SecretKind] { SecretDetector.findings(in: text).map(\.kind) }

    /// 0: 大文字・1: 小文字・2: 数字
    static func category(_ character: Character) -> Int? {
        if character.isASCII, character.isUppercase { return 0 }
        if character.isASCII, character.isLowercase { return 1 }
        if character.isASCII, character.isNumber { return 2 }
        return nil
    }

    @Test("頭は決まった並びで、大文字 → 小文字 → 数字と巡り、種類の中では一巡するまで重ならない", arguments: [0, 3, 6, 8, 12, 20, 40, 80, 512])
    func shape(count: Int) {
        for seed in Self.seeds {
            let characters = Array(Self.body(count, seed: seed))
            let length = characters.count
            let headMatches = characters.prefix(6) == fakeSecretHead.prefix(count)
            let cycles = characters.enumerated().allSatisfy { Self.category($1) == $0 % 3 }
            let rest = characters.dropFirst(6)
            let headRepeated = rest.contains { fakeSecretHead.contains($0) }
            // 種類ごとに、引いた順に「その種類の数」ずつ区切ると、区切りの中は重ならない
            let distinctInRounds = [(0, 24), (1, 24), (2, 8)].allSatisfy { kind, poolSize in
                let drawn = Array(rest.filter { Self.category($0) == kind })
                return stride(from: 0, to: drawn.count, by: poolSize).allSatisfy { start in
                    let round = drawn[start..<min(start + poolSize, drawn.count)]
                    return Set(round).count == round.count
                }
            }
            #expect(length == count)
            #expect(headMatches, "\(count) 文字・種 \(seed): 頭が決まった並びでない")
            #expect(cycles, "\(count) 文字・種 \(seed): 種類が巡りどおりでない")
            #expect(!headRepeated, "\(count) 文字・種 \(seed): 頭の文字が後ろに出た")
            #expect(distinctInRounds, "\(count) 文字・種 \(seed): 一巡の中で文字が重なった")
        }
    }

    @Test("20〜512 文字なら、必ずランダムな文字列（確度「中」）とだけ判定される", arguments: [20, 21, 22, 23, 32, 40, 48, 64, 80, 512])
    func alwaysRandomToken(count: Int) {
        for seed in Self.seeds {
            let findings = SecretDetector.findings(in: Self.body(count, seed: seed))
            let kinds = findings.map(\.kind)
            let location = findings.first?.location
            let length = findings.first?.length
            #expect(kinds == [.randomToken], "\(count) 文字・種 \(seed) が確度「中」の 1 件にならない")
            #expect(location == 0)
            #expect(length == count)
        }
    }

    @Test("短くても、ランダムらしさの判定（looksRandom）には必ず通り、プレースホルダにも見えない", arguments: [8, 9, 10, 12, 16, 19])
    func shortBodiesLookRandom(count: Int) {
        for seed in Self.seeds {
            let text = Self.body(count, seed: seed)
            let random = SecretDetector.looksRandom(text)
            let placeholder = SecretDetector.isPlaceholder(text)
            #expect(random, "\(count) 文字・種 \(seed) がランダムらしくない")
            #expect(!placeholder, "\(count) 文字・種 \(seed) がプレースホルダに見える")
        }
    }

    @Test("長さの境界: 19 文字と 513 文字は、文字列全体のランダムな文字列にはしない")
    func lengthBoundary() {
        for seed in Self.seeds.prefix(50) {
            let kinds = [19, 20, 512, 513].map { Self.kinds(Self.body($0, seed: seed)) }
            #expect(kinds == [[], [.randomToken], [.randomToken], []], "種 \(seed)")
        }
    }

    @Test("E2E の形（secret-github・secret-openai・secret-env・secret-image-url）は、必ず確度「高」")
    func e2eFixturesAreHigh() {
        for seed in Self.seeds {
            var generator = SeededGenerator(state: seed)
            let cases: [(String, String, SecretKind?)] = [
                ("secret-github", "gh" + "p_" + fakeSecretBody(36, using: &generator), .githubToken),
                ("secret-openai", "sk-" + "test-" + fakeSecretBody(32, using: &generator), .openAIKey),
                (
                    "secret-env の接続文字列",
                    "DATABASE_URL=postgres://app:\(fakeSecretBody(12, using: &generator))@localhost:5432/app", nil
                ),
                (
                    "secret-image-url",
                    "https://cdn.example.com/e2e-0A1B2C3D.png?token=" + fakeSecretBody(32, using: &generator), nil
                ),
            ]
            for (name, text, kind) in cases {
                let findings = SecretDetector.findings(in: text)
                let confidence = SecretDetector.confidence(of: findings)
                let kinds = findings.map(\.kind)
                #expect(confidence == .high, "\(name)・種 \(seed) が確度「高」にならない")
                if let kind { #expect(kinds == [kind], "\(name)・種 \(seed) の種類が違う") }
            }
        }
    }

    @Test("Base64 として読んでも、画像の頭や文章を符号化したものに見えない（80 文字まで）", arguments: [8, 20, 40, 60, 80])
    func notEncodedNonSecret(count: Int) {
        for seed in Self.seeds {
            let encoded = SecretDetector.isEncodedNonSecret(Self.body(count, seed: seed))
            #expect(!encoded, "\(count) 文字・種 \(seed)")
        }
    }

    @Test("種を決めなければ、呼ぶたびに違う値になる")
    func differsEachCall() {
        let distinct = Set((0..<20).map { _ in fakeSecretBody(40) }).count
        #expect(distinct == 20)
    }

    @Test("秘密鍵の本体の行は Base64 の文字だけで、指定した長さ")
    func base64Line() {
        let line = fakeBase64Line(64)
        let length = line.count
        let base64Only = line.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }
        #expect(length == 64)
        #expect(base64Only)
    }
}
