import CryptoKit
import Foundation
import Testing

@testable import MakuripCore

/// テスト用の偽の秘密。本物の形式どおりの長い値をソースに直書きしない（GitHub の secret scanning が反応しうるため）。
/// 決まった種から作る擬似乱数の文字列を、実行時に接頭辞とつなぐ。どれも実在しない値
enum FakeSecret {
    static let alphanumerics = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let digits = Array("0123456789")
    static let base64 = alphanumerics + ["+", "/"]

    /// 決まった種から作る擬似乱数の文字列（線形合同法の上位ビット）
    static func random(_ count: Int, seed: UInt64 = 1, alphabet: [Character] = alphanumerics) -> String {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var result = ""
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            result.append(alphabet[Int((state >> 33) % UInt64(alphabet.count))])
        }
        return result
    }

    static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // 形式ごとの偽物（接頭辞は文字列をつないで作る）
    static let anthropic = "sk-" + "ant-" + "api03-" + random(93, seed: 11) + "AA"
    static let openAIProject = "sk-" + "proj-" + random(64, seed: 12)
    /// 試作の例と同じ形（`sk-test-…`）
    static let openAITest = "sk-" + "test-" + random(28, seed: 13)
    static let github = "gh" + "p_" + random(36, seed: 14)
    static let githubFineGrained = "github" + "_pat_" + random(22, seed: 15) + "_" + random(59, seed: 16)
    static let gitlab = "gl" + "pat-" + random(20, seed: 17)
    static let slackBot =
        "xo" + "xb-" + random(12, seed: 18, alphabet: digits) + "-" + random(13, seed: 19, alphabet: digits) + "-"
        + random(24, seed: 20)
    static let slackWebhook =
        "https://hooks.slack.com/" + "services/T" + random(8, seed: 21) + "/B" + random(8, seed: 22) + "/"
        + random(24, seed: 23)
    static let discordWebhook =
        "https://discord.com/api/" + "webhooks/" + random(18, seed: 24, alphabet: digits) + "/" + random(68, seed: 25)
    /// AWS の公式ドキュメントにある例示用のアクセスキー ID
    static let awsAccessKey = "AK" + "IA" + "IOSFODNN7EXAMPLE"
    static let google = "AI" + "za" + random(35, seed: 26)
    static let stripe = "sk" + "_live_" + random(24, seed: 27)
    static let stripeWebhook = "wh" + "sec_" + random(32, seed: 28)
    static let npm = "np" + "m_" + random(36, seed: 29)
    static let huggingFace = "hf" + "_" + random(34, seed: 30, alphabet: letters)
    static let sendGrid = "SG" + "." + random(22, seed: 31) + "." + random(43, seed: 32)
    static let jwt =
        base64URL(#"{"alg":"HS256","typ":"JWT"}"#) + "." + base64URL(#"{"sub":"1234567890","name":"Test"}"#) + "."
        + random(43, seed: 33)
    static let privateKeyBody = (0..<6).map { random(64, seed: 40 + UInt64($0), alphabet: base64) }.joined(
        separator: "\n")
    static let privateKey =
        "-----BEGIN " + "RSA PRIVATE KEY-----\n" + privateKeyBody + "\n-----END " + "RSA PRIVATE KEY-----"
    static let openSSHKey =
        "-----BEGIN " + "OPENSSH PRIVATE KEY-----\n" + privateKeyBody + "\n-----END " + "OPENSSH PRIVATE KEY-----"
    static let randomToken = random(40, seed: 50)
}

@Suite("秘密の判定（陽性: 既知の形式）")
struct SecretDetectorPositiveTests {
    static let cases: [(String, SecretKind)] = [
        (FakeSecret.anthropic, .anthropicKey),
        (FakeSecret.openAIProject, .openAIKey),
        (FakeSecret.openAITest, .openAIKey),
        (FakeSecret.github, .githubToken),
        (FakeSecret.githubFineGrained, .githubToken),
        (FakeSecret.gitlab, .gitlabToken),
        (FakeSecret.slackBot, .slackToken),
        (FakeSecret.slackWebhook, .slackWebhook),
        (FakeSecret.discordWebhook, .discordWebhook),
        (FakeSecret.awsAccessKey, .awsAccessKey),
        (FakeSecret.google, .googleAPIKey),
        (FakeSecret.stripe, .stripeKey),
        (FakeSecret.stripeWebhook, .stripeKey),
        (FakeSecret.npm, .npmToken),
        (FakeSecret.huggingFace, .huggingFaceToken),
        (FakeSecret.sendGrid, .sendGridKey),
        (FakeSecret.jwt, .jwt),
        (FakeSecret.privateKey, .privateKey),
        (FakeSecret.openSSHKey, .privateKey),
    ]

    @Test("値だけをコピーしても、文の中にあっても、既知の形式なら確度「高」で見つける", arguments: cases)
    func knownFormat(value: String, kind: SecretKind) throws {
        for text in [value, "キーはこれです: \(value) （あとで消す）", "export X=\"\(value)\""] {
            let findings = SecretDetector.findings(in: text)
            let finding = try #require(findings.first, "\(kind) を見つけられない")
            #expect(findings.count == 1)
            #expect(finding.kind == kind)
            #expect(finding.confidence == .high)
            // 範囲は値そのもの
            #expect((text as NSString).substring(with: finding.range) == value)
        }
    }

    @Test("認証ヘッダー（curl の -H の中・ラベルなしの Bearer・API キーのヘッダー）")
    func headers() throws {
        let token = FakeSecret.random(40, seed: 60)
        let basic = Data("user:\(FakeSecret.random(12, seed: 61))".utf8).base64EncodedString()
        let cases = [
            "curl -H \"Authorization: Bearer \(token)\" https://api.example.com/v1/items",
            "Authorization: Basic \(basic)",
            "Bearer \(token)",
            "curl -H 'X-API-Key: \(token)' https://api.example.com",
            "PRIVATE-TOKEN: \(token)",
        ]
        for text in cases {
            let findings = SecretDetector.findings(in: text)
            #expect(findings.map(\.kind) == [.authorizationHeader], "\(text.prefix(20))")
            #expect(findings.first?.confidence == .high)
        }
    }

    @Test(".env・設定ファイル・JSON・YAML・URL のクエリ・CLI の引数の代入")
    func assignments() {
        let value = FakeSecret.random(32, seed: 62)
        let cases: [(String, SecretKind)] = [
            ("OPENAI_API_KEY=\(value)", .secretAssignment),
            ("export API_TOKEN=tok-test-\(FakeSecret.random(16, seed: 63))", .secretAssignment),
            ("DB_PASSWORD=hunter2!", .passwordAssignment),
            ("POSTGRES_PASSWORD=postgres", .passwordAssignment),
            ("SECRET_KEY_BASE=\(value)", .secretAssignment),
            ("aws_secret_access_key = \(value)", .secretAssignment),
            ("client = OpenAI(api_key=\"\(value)\")", .secretAssignment),
            ("{\"client_secret\":\"\(value)\",\"name\":\"app\"}", .secretAssignment),
            ("  password: \"s3cr3t-Value\"", .passwordAssignment),
            ("  POSTGRES_PASSWORD: postgres", .passwordAssignment),
            ("data:\n  password: cGFzc3dvcmQxMjM=", .passwordAssignment),
            ("https://example.com/reset?email=a%40example.com&token=\(value)", .secretAssignment),
            ("mysql --password=Abc123xyz! -u app", .passwordAssignment),
            ("STRIPE_KEY=\(value)", .secretAssignment),
            ("GITHUB_TOKEN_2=\(value)", .secretAssignment),
        ]
        for (text, kind) in cases {
            let findings = SecretDetector.findings(in: text)
            #expect(findings.map(\.kind) == [kind], "\(text.prefix(24))")
        }
    }

    @Test("URL の中のパスワード（接続文字列）")
    func urlCredentials() throws {
        let text = "DATABASE_URL=postgres://app:Sup3rS3cret@db.example.com:5432/app"
        let finding = try #require(SecretDetector.findings(in: text).first)
        #expect(finding.kind == .urlCredentials)
        #expect((text as NSString).substring(with: finding.range) == "Sup3rS3cret")
    }

    @Test(".env を丸ごと: 秘密の行だけを見つけ、ほかの行は見つけない")
    func wholeEnvFile() {
        let text = """
            # アプリの設定
            NODE_ENV=production
            PORT=3000
            OPENAI_API_KEY=\(FakeSecret.openAIProject)
            DATABASE_URL=postgres://app:Sup3rS3cret@localhost:5432/app
            MAX_TOKENS=4096
            DEBUG=false
            GITHUB_TOKEN=\(FakeSecret.github)
            """
        let kinds = SecretDetector.findings(in: text).map(\.kind)
        #expect(kinds == [.openAIKey, .urlCredentials, .githubToken])
    }

    @Test("形式から外れる長いランダムな文字列は、確度「中」")
    func randomToken() throws {
        let finding = try #require(SecretDetector.findings(in: "  \(FakeSecret.randomToken)\n").first)
        #expect(finding.kind == .randomToken)
        #expect(finding.confidence == .medium)
        #expect(finding.location == 2)
        #expect(SecretDetector.confidence(of: [finding]) == .medium)
    }
}

@Suite("秘密の判定（陰性: 紛らわしいもの）")
struct SecretDetectorNegativeTests {
    static func pngBase64(_ length: Int) -> String {
        // PNG の頭（8 バイトの印と IHDR）に、擬似乱数のバイトを続けたもの
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        let filler = FakeSecret.random(length, seed: 70)
        bytes += Array(filler.utf8).map { $0 &* 7 }
        return Data(bytes).base64EncodedString()
    }

    static let cases: [(String, String)] = [
        ("UUID（大文字）", UUID().uuidString),
        ("UUID（小文字）", UUID().uuidString.lowercased()),
        ("UUID（区切りなし）", UUID().uuidString.replacingOccurrences(of: "-", with: "")),
        ("git のハッシュ", FakeSecret.random(40, seed: 71, alphabet: Array("0123456789abcdef"))),
        ("git の短いハッシュ", "3f78685"),
        ("SHA-256", SHA256.hash(data: Data("hello".utf8)).map { String(format: "%02x", $0) }.joined()),
        ("Base64 の画像（短い）", pngBase64(60)),
        ("Base64 の画像（長い）", pngBase64(3000)),
        ("data URL の画像", "data:image/png;base64," + pngBase64(200)),
        ("1x1 の GIF", "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"),
        ("Base64 の文章", Data("This is a plain sentence, encoded in base64 for transport.".utf8).base64EncodedString()),
        (
            "英文",
            "The quick brown fox jumps over the lazy dog. Please rotate your API key every 90 days and never share your token."
        ),
        ("日本語", "パスワードを入力してください。トークンの有効期限は 30 日です。"),
        ("URL（GitHub）", "https://github.com/takushio2525/makurip/pull/18"),
        ("URL（動画）", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s"),
        ("URL（文書の ID）", "https://docs.google.com/document/d/1aBcD3fGhIjK4LmNoPqR5sTuVwXyZ06789AbCdEfG/edit"),
        ("URL（ユーザー名だけ）", "ssh://git@example.com:22/repo.git"),
        ("識別子", "NSPasteboardTypeStringUTF8PlainTextWithLongName"),
        ("識別子（数字入り）", "base64EncodedStringWithOptions2"),
        ("製品名", "MyAwesomeProject2024FinalVersion"),
        ("版", "v1.2.3-beta.4+build.567"),
        ("ULID", "01ARZ3NDEKTSV4RRFFQ69G5FAV"),
        ("ファイルのパス", "/Users/someone/Library/Application Support/Makurip/blobs/0F8A/0-1.bin"),
        ("メールアドレス", "someone.example@example.com"),
        ("sk- で始まる英単語の並び", "sk-learn-tutorial-for-beginners-and-experts"),
        ("task- の中の sk-", "task-force-alpha-2024-quarterly-report-final"),
        ("公開してよい Stripe のキー", "pk" + "_live_" + FakeSecret.random(24, seed: 72)),
        ("公開鍵", "-----BEGIN PUBLIC KEY-----\n" + FakeSecret.privateKeyBody + "\n-----END PUBLIC KEY-----"),
        ("証明書", "-----BEGIN CERTIFICATE-----\n" + FakeSecret.privateKeyBody + "\n-----END CERTIFICATE-----"),
        ("hf_ の識別子", "hf_TransformerModelForSequenceClassification"),
        ("同じ文字の繰り返し", "sk-test-" + String(repeating: "X", count: 24) + "0000"),
    ]

    @Test("秘密として見つけない", arguments: cases)
    func notSecret(name: String, text: String) {
        #expect(SecretDetector.findings(in: text).isEmpty, "\(name) を秘密と判定した")
    }

    @Test("コードの中の token・password という語は拾わない")
    func codeWithTokenWord() {
        let swift = """
            struct Credentials {
                let apiKey: String
                var token: String?
                password: String
            }

            func authorize(_ request: inout URLRequest) async throws {
                let token = try await auth.fetchToken()
                guard let token else { return }
                request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization")
            }
            """
        let python = """
            def get_token(self) -> str:
                token = self.session.get("token")
                api_key = os.environ["OPENAI_API_KEY"]
                password = getpass()
                return token
            """
        let javascript = """
            const headers = { Authorization: `Bearer ${token}` };
            const TOKEN_KEY = "auth_token";
            const config = { apiKey: process.env.API_KEY, password: input.value };
            const tokenizer = new Tokenizer({ maxTokens: 4096 });
            """
        let config = """
            MAX_TOKENS=4096
            TOKEN_LIMIT=100
            PASSWORD_MIN_LENGTH=8
            API_KEY=your-api-key-here
            OPENAI_API_KEY=<your key>
            GITHUB_TOKEN=${{ secrets.GITHUB_TOKEN }}
            export GITHUB_TOKEN=$(gh auth token)
            SECRET=
            "nextPageToken": "CiAKGjBpNDd2Nmp2Zml2cXRtcTBzanZ1a3Rj"
            "password": "Password"
            "password": "パスワード"
            "eos_token": "</s>"
            NEXT_PUBLIC_API_URL=https://api.example.com
            PUBLIC_KEY=\(FakeSecret.random(32, seed: 73))
            SORT_KEY=created_at
            """
        for (name, text) in [("Swift", swift), ("Python", python), ("JavaScript", javascript), ("設定", config)] {
            let findings = SecretDetector.findings(in: text)
            #expect(findings.isEmpty, "\(name): \(findings.map(\.kind))")
        }
    }
}

@Suite("伏せ字の作り方")
struct SecretMaskTests {
    /// 伏せ字に、隠した部分の 6 文字以上の並びが 1 つも残っていない（中身を復元できない）
    func expectHidden(_ masked: String, secret: String, visiblePrefix: Int, tail: Int) {
        let hidden = Array(secret.dropFirst(visiblePrefix).dropLast(tail))
        guard hidden.count >= 6 else { return }
        for start in 0...(hidden.count - 6) {
            let window = String(hidden[start..<(start + 6)])
            #expect(!masked.contains(window), "隠した部分が残っている")
        }
    }

    @Test("決まった接頭辞と末尾 4 文字だけを見せる（試作の sk-test-••••••••••••••••0000）")
    func prefixAndTail() {
        let value = FakeSecret.openAITest
        let (masked, findings) = SecretMask.masked(value)
        #expect(findings.count == 1)
        #expect(masked == "sk-test-" + String(repeating: "•", count: 16) + String(value.suffix(4)))
        expectHidden(masked, secret: value, visiblePrefix: 8, tail: 4)
    }

    @Test("短い値は末尾も見せない。伏せ字の数は 8 か 16 で、元の長さは分からない")
    func shortValues() {
        #expect(SecretMask.masked(FakeSecret.awsAccessKey).text == "AKIA" + String(repeating: "•", count: 16))
        #expect(SecretMask.masked("DB_PASSWORD=hunter2!").text == "DB_PASSWORD=" + String(repeating: "•", count: 8))
        let long = SecretMask.masked("DB_PASSWORD=" + FakeSecret.random(40, seed: 80)).text
        #expect(long == "DB_PASSWORD=" + String(repeating: "•", count: 16), "パスワードは長くても末尾を見せない")
        let a = SecretMask.masked(FakeSecret.github).text
        let b = SecretMask.masked("gh" + "p_" + FakeSecret.random(60, seed: 81)).text
        #expect(a.count == b.count, "長さの違う値が同じ長さの伏せ字になる")
    }

    @Test("秘密鍵は BEGIN と END の行だけを残し、中身は伏せる")
    func privateKey() {
        let masked = SecretMask.masked(FakeSecret.privateKey).text
        #expect(
            masked == "-----BEGIN RSA PRIVATE KEY-----\n" + String(repeating: "•", count: 16)
                + "\n-----END RSA PRIVATE KEY-----")
        for line in FakeSecret.privateKeyBody.split(separator: "\n") {
            #expect(!masked.contains(line.prefix(8)))
        }
    }

    @Test(".env を丸ごと: 秘密の値だけを伏せ、ほかの行と名前は残す")
    func envFile() {
        let text = "NODE_ENV=production\nOPENAI_API_KEY=\(FakeSecret.openAIProject)\nDB_PASSWORD=hunter2!\nPORT=3000"
        let masked = SecretMask.masked(text).text
        let lines = masked.split(separator: "\n").map(String.init)
        #expect(lines[0] == "NODE_ENV=production")
        #expect(lines[1].hasPrefix("OPENAI_API_KEY=sk-proj-••••"))
        #expect(lines[2] == "DB_PASSWORD=••••••••")
        #expect(lines[3] == "PORT=3000")
        expectHidden(masked, secret: FakeSecret.openAIProject, visiblePrefix: 8, tail: 4)
    }

    @Test("ランダムな文字列は接頭辞なしで末尾 4 文字だけ")
    func randomToken() {
        let value = FakeSecret.randomToken
        #expect(SecretMask.masked(value).text == String(repeating: "•", count: 16) + value.suffix(4))
    }

    @Test("秘密がなければ元のまま")
    func nothing() {
        #expect(SecretMask.masked("ふつうのメモ").text == "ふつうのメモ")
        #expect(SecretMask.masked("ふつうのメモ").findings.isEmpty)
    }
}

@Suite("秘密の判定（スナップショット・一覧用の平文・とても長いもの）")
struct SecretScannerTests {
    func snapshot(_ representations: [(String, Data)]) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [
            PasteboardItemSnapshot(
                representations: representations.map { PasteboardRepresentation(type: $0.0, data: $0.1) })
        ])
    }

    func context() -> CapturePipeline.Context {
        CapturePipeline.Context(now: Date(timeIntervalSince1970: 1_800_000_000), frontmostApp: nil, copyMethod: .other)
    }

    @Test("取り込みで印を付け、一覧用の平文を伏せ字にする（確度「高」は自動消去の印も）")
    func captureFlagsAndMasks() throws {
        let text = "export OPENAI_API_KEY=\(FakeSecret.openAIProject)"
        let decision = CapturePipeline.process(
            snapshot([(PasteboardTypes.utf8PlainText, Data(text.utf8))]), context: context(), limits: .default)
        guard case .accept(let clip) = decision else {
            Issue.record("取り込まなかった")
            return
        }
        #expect(clip.flags == [.secretLikely, .secretKnownFormat])
        let preview = try #require(clip.previewText)
        #expect(preview.hasPrefix("export OPENAI_API_KEY=sk-proj-••••"))
        #expect(!preview.contains(String(FakeSecret.openAIProject.dropFirst(8).prefix(12))))
    }

    @Test("ランダムな文字列だけなら、マスクの印だけ（自動消去の印は付けない）")
    func mediumFlags() throws {
        let decision = CapturePipeline.process(
            snapshot([(PasteboardTypes.utf8PlainText, Data(FakeSecret.randomToken.utf8))]), context: context(),
            limits: .default)
        guard case .accept(let clip) = decision else {
            Issue.record("取り込まなかった")
            return
        }
        #expect(clip.flags == [.secretLikely])
    }

    @Test("ふつうの文章には印を付けず、平文もそのまま")
    func plainText() throws {
        let decision = CapturePipeline.process(
            snapshot([(PasteboardTypes.utf8PlainText, Data("明日の打ち合わせは 10 時から".utf8))]), context: context(),
            limits: .default)
        guard case .accept(let clip) = decision else {
            Issue.record("取り込まなかった")
            return
        }
        #expect(clip.flags.isEmpty)
        #expect(clip.previewText == "明日の打ち合わせは 10 時から")
    }

    @Test("平文のない RTF の中の秘密も見つける")
    func rtfOnly() throws {
        let rtf = #"{\rtf1\ansi\deff0 {\fonttbl {\f0 Helvetica;}} \f0 key: "# + FakeSecret.github + #" \par }"#
        let assessment = try #require(SecretScanner.assess(snapshot([(PasteboardTypes.rtf, Data(rtf.utf8))])))
        #expect(assessment.kinds == [.githubToken])
        #expect(assessment.confidence == .high)
    }

    @Test("ファイルの名前・パスの中の秘密（一覧用の名前も伏せ字）")
    func fileName() throws {
        let name = FakeSecret.github + ".txt"
        let url = URL(fileURLWithPath: "/tmp/keys/\(name)").absoluteString
        let snap = snapshot([(PasteboardTypes.fileURL, Data(url.utf8))])
        #expect(SecretScanner.assess(snap)?.kinds == [.githubToken])
        let preview = try #require(
            PreviewText.make(for: snap, kind: .file, limit: 1000, maskSecrets: true))
        #expect(preview.hasPrefix("ghp_••••"))
        #expect(!preview.contains(String(FakeSecret.github.dropFirst(4).prefix(10))))
    }

    @Test("画像に添えられた URL の中の秘密（ブラウザの「画像をコピー」）")
    func imageWithSignedURL() throws {
        let url = "https://cdn.example.com/a.png?token=\(FakeSecret.random(32, seed: 90))"
        let snap = snapshot([
            (PasteboardTypes.png, Data([0x89, 0x50, 0x4E, 0x47])), (PasteboardTypes.utf8PlainText, Data(url.utf8)),
        ])
        #expect(KindClassifier.classify(snap) == .image)
        #expect(SecretScanner.assess(snap)?.confidence == .high)
    }

    @Test("一覧用の平文の境目（先頭 1000 文字）にかかる秘密も、のぞかない")
    func previewBoundary() throws {
        let filler = String(repeating: "あ", count: 990)
        let text = filler + " " + FakeSecret.openAIProject
        let preview = try #require(
            PreviewText.make(
                for: snapshot([(PasteboardTypes.utf8PlainText, Data(text.utf8))]), kind: .text, limit: 1000,
                maskSecrets: true))
        #expect(preview.count == 1000)
        #expect(preview.hasSuffix(" sk-proj-•"))
    }

    @Test("とても長い文字列（2 MB）: 先頭の秘密は見つけ、時間もかからない。先頭 512K より後ろは見ない（限界）")
    func veryLongText() throws {
        let line = "2026-10-31T12:00:00Z INFO request served path=/api/v1/items status=200 duration=12ms\n"
        let log = String(repeating: line, count: 2_000_000 / line.utf8.count)
        let start = Date()
        let head = SecretDetector.findings(in: "GITHUB_TOKEN=\(FakeSecret.github)\n" + log)
        let elapsed = Date().timeIntervalSince(start)
        #expect(head.map(\.kind) == [.githubToken])
        #expect(elapsed < 3, "長い文字列の判定に \(elapsed) 秒かかった")
        #expect(SecretDetector.findings(in: log + FakeSecret.github).isEmpty)
    }
}
