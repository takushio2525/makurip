import Foundation
import Testing

@testable import MakuripCore

/// テスト用の Release の一覧（GitHub の `GET /releases` の形）
enum FeedFixture {
    static func asset(_ name: String, base: String = "https://github.com/takushio2525/makurip/releases/download")
        -> [String: JSONValue]
    {
        let tag = name.split(separator: "-").last.map { "v" + $0.replacingOccurrences(of: ".zip.sha256", with: "") }
        let version = tag?.replacingOccurrences(of: ".zip", with: "") ?? "v0.0.0"
        return [
            "name": .string(name), "size": .int(1234), "state": .string("uploaded"),
            "browser_download_url": .string("\(base)/\(version)/\(name)"),
        ]
    }

    static func release(
        _ version: String, draft: Bool = false, prerelease: Bool = false, tag: String? = nil,
        assets: [[String: JSONValue]]? = nil
    ) -> JSONValue {
        .object([
            "tag_name": .string(tag ?? "v\(version)"), "draft": .bool(draft), "prerelease": .bool(prerelease),
            "html_url": .string("https://github.com/takushio2525/makurip/releases/tag/v\(version)"),
            "published_at": .string("2026-11-04T00:00:00Z"),
            "assets": .array(
                (assets ?? [asset("Makurip-\(version).zip"), asset("Makurip-\(version).zip.sha256")]).map(
                    JSONValue.object)),
        ])
    }

    static func data(_ releases: [JSONValue]) -> Data {
        Data(JSONValue.array(releases).compactText.utf8)
    }

    /// 作った Release（`UpdateBench.publish`）を、そのままの URL・大きさで一覧の形にする
    static func entry(_ release: UpdateRelease) -> JSONValue {
        func asset(_ asset: ReleaseAsset) -> JSONValue {
            var object: [String: JSONValue] = [
                "name": .string(asset.name), "state": .string("uploaded"),
                "browser_download_url": .string(asset.url.absoluteString),
            ]
            if let size = asset.size { object["size"] = .int(size) }
            return .object(object)
        }
        return .object([
            "tag_name": .string(release.tag), "draft": .bool(false), "prerelease": .bool(false),
            "assets": .array([asset(release.archive), asset(release.checksum)]),
        ])
    }
}

@Suite("アップデート: 版の比較")
struct AppVersionTests {
    @Test("X.Y.Z と vX.Y.Z を読み、数として比べる")
    func parseAndCompare() throws {
        let a = try #require(AppVersion("0.1.0"))
        let b = try #require(AppVersion("v0.1.0"))
        #expect(a == b)
        #expect(a.tag == "v0.1.0")
        #expect(a.description == "0.1.0")
        #expect(try #require(AppVersion("0.10.0")) > #require(AppVersion("0.9.9")))
        #expect(try #require(AppVersion("1.0.0")) > #require(AppVersion("0.99.99")))
        #expect(try #require(AppVersion("0.1.1")) > a)
        #expect(!(a < b) && !(b < a))
    }

    @Test(
        "形の違うものは版にしない（2 つ・4 つ・後ろ書き・先頭の 0・空・数字でない）",
        arguments: [
            "", "0.1", "0.1.0.1", "v0.1.0-beta", "0.1.0-rc.1", "01.1.0", "0.01.0", "a.b.c", "v", "0..1", " ", "1.2.3 ",
            "１.２.３",
        ])
    func rejects(_ text: String) {
        if text == "1.2.3 " {
            // 前後の空白は落として読む（Info.plist の手入力の揺れ）
            #expect(AppVersion(text) == AppVersion(major: 1, minor: 2, patch: 3))
        } else {
            #expect(AppVersion(text) == nil)
        }
    }
}

@Suite("アップデート: Release の読み取り")
struct ReleaseFeedTests {
    @Test("一覧から新しい版の順に、添付のそろったものを読む")
    func parsesList() throws {
        let data = FeedFixture.data([FeedFixture.release("0.1.0"), FeedFixture.release("0.2.0")])
        let releases = try ReleaseFeed.parse(data)
        #expect(releases.map(\.version.description) == ["0.2.0", "0.1.0"])
        let latest = try #require(releases.first)
        #expect(latest.tag == "v0.2.0")
        #expect(latest.archive.name == "Makurip-0.2.0.zip")
        #expect(latest.checksum.name == "Makurip-0.2.0.zip.sha256")
        #expect(latest.archive.size == 1234)
        #expect(latest.pageURL?.absoluteString == "https://github.com/takushio2525/makurip/releases/tag/v0.2.0")
        #expect(latest.publishedAt != nil)
    }

    @Test("prerelease と draft は除く")
    func skipsPrereleaseAndDraft() throws {
        let data = FeedFixture.data([
            FeedFixture.release("0.3.0", prerelease: true), FeedFixture.release("0.4.0", draft: true),
            FeedFixture.release("0.2.0"),
        ])
        #expect(try ReleaseFeed.latest(in: data)?.version.description == "0.2.0")
        // prerelease だけなら、入れられるものはない
        let only = FeedFixture.data([FeedFixture.release("0.3.0", prerelease: true)])
        #expect(try ReleaseFeed.latest(in: only) == nil)
    }

    @Test("tag の形が違う・添付が欠ける・名前の版が違う・同じ名前が 2 つの Release は選ばない")
    func skipsBrokenReleases() throws {
        let data = FeedFixture.data([
            FeedFixture.release("0.9.0", tag: "0.9.0"),  // v がない
            FeedFixture.release("0.8.0", tag: "v0.8.0-beta"),
            FeedFixture.release("0.7.0", assets: [FeedFixture.asset("Makurip-0.7.0.zip")]),  // sha256 がない
            FeedFixture.release(
                "0.6.0",
                assets: [FeedFixture.asset("Makurip-0.5.0.zip"), FeedFixture.asset("Makurip-0.5.0.zip.sha256")]),
            FeedFixture.release(
                "0.5.5",
                assets: [
                    FeedFixture.asset("Makurip-0.5.5.zip"), FeedFixture.asset("Makurip-0.5.5.zip"),
                    FeedFixture.asset("Makurip-0.5.5.zip.sha256"),
                ]),
            FeedFixture.release("0.1.0"),
        ])
        #expect(try ReleaseFeed.parse(data).map(\.version.description) == ["0.1.0"])
    }

    @Test("アップロードの途中の添付は使わない")
    func skipsIncompleteUpload() throws {
        var zip = FeedFixture.asset("Makurip-0.2.0.zip")
        zip["state"] = .string("starter")
        let data = FeedFixture.data([
            FeedFixture.release("0.2.0", assets: [zip, FeedFixture.asset("Makurip-0.2.0.zip.sha256")])
        ])
        #expect(try ReleaseFeed.latest(in: data) == nil)
    }

    @Test("1 件の形（/releases/latest）も読める。空の一覧は Release なし")
    func singleAndEmpty() throws {
        let single = Data(FeedFixture.release("0.2.0").compactText.utf8)
        #expect(try ReleaseFeed.latest(in: single)?.version.description == "0.2.0")
        #expect(try ReleaseFeed.latest(in: Data("[]".utf8)) == nil)
    }

    @Test("JSON でない・形が違うものは feedUnreadable", arguments: ["", "not json", "{\"message\":\"Not Found\"}", "42"])
    func unreadable(_ text: String) {
        #expect(throws: UpdateFailure.feedUnreadable) { try ReleaseFeed.parse(Data(text.utf8)) }
    }

    @Test("添付の digest（sha256:…）を読む。形が違えば使わない")
    func digest() throws {
        let hex = String(repeating: "ab", count: 32)
        var zip = FeedFixture.asset("Makurip-0.2.0.zip")
        zip["digest"] = .string("sha256:" + hex.uppercased())
        var sha = FeedFixture.asset("Makurip-0.2.0.zip.sha256")
        sha["digest"] = .string("md5:1234")
        let data = FeedFixture.data([FeedFixture.release("0.2.0", assets: [zip, sha])])
        let release = try #require(try ReleaseFeed.latest(in: data))
        #expect(release.archive.sha256 == hex)
        #expect(release.checksum.sha256 == nil)
    }
}

@Suite("アップデート: 知らせるかの判断と「この版は知らせない」")
struct UpdateAvailabilityTests {
    static func release(_ version: String) throws -> UpdateRelease {
        try #require(try ReleaseFeed.latest(in: FeedFixture.data([FeedFixture.release(version)])))
    }

    @Test("新しければ知らせ、同じ・古い・無いなら最新")
    func compare() throws {
        let current = try #require(AppVersion("0.2.0"))
        #expect(
            UpdateAvailability.of(current: current, latest: try Self.release("0.3.0"), skippedVersion: nil).isAvailable)
        #expect(
            UpdateAvailability.of(current: current, latest: try Self.release("0.2.0"), skippedVersion: nil) == .upToDate
        )
        #expect(
            UpdateAvailability.of(current: current, latest: try Self.release("0.1.0"), skippedVersion: nil) == .upToDate
        )
        #expect(UpdateAvailability.of(current: current, latest: nil, skippedVersion: nil) == .upToDate)
    }

    @Test("「この版は知らせない」はその版だけ。さらに新しい版が出たら知らせる")
    func skip() throws {
        let current = try #require(AppVersion("0.1.0"))
        let v2 = try Self.release("0.2.0")
        #expect(UpdateAvailability.of(current: current, latest: v2, skippedVersion: "0.2.0") == .skipped(v2))
        #expect(UpdateAvailability.of(current: current, latest: v2, skippedVersion: "v0.2.0") == .skipped(v2))
        #expect(
            UpdateAvailability.of(current: current, latest: try Self.release("0.3.0"), skippedVersion: "0.2.0")
                .isAvailable)
        // 壊れた値は知らせないことにしない
        #expect(UpdateAvailability.of(current: current, latest: v2, skippedVersion: "そのうち").isAvailable)
    }

    @Test("状態のファイルに書いて読み直せる。壊れたファイルは空の状態")
    func stateFile() throws {
        let folder = TemporaryDirectory()
        let file = UpdateStateFile(directory: folder.url)
        #expect(file.load() == UpdateState())
        let state = UpdateState(
            lastCheckedAt: Date(timeIntervalSince1970: 1_800_000_000), latest: try Self.release("0.2.0"),
            skippedVersion: "0.2.0", lastError: nil)
        try file.save(state)
        #expect(file.load() == state)
        #expect(
            file.load().availability(current: try #require(AppVersion("0.1.0"))) == .skipped(try Self.release("0.2.0")))
        try Data("{".utf8).write(to: file.url)
        #expect(file.load() == UpdateState())
    }
}

@Suite("アップデート: sha256 のファイル")
struct UpdateChecksumTests {
    static let hex = String(repeating: "0123456789abcdef", count: 4)

    @Test("shasum -a 256 の 1 行を読む（* の印・大文字・末尾の改行も）")
    func parses() throws {
        let name = "Makurip-0.2.0.zip"
        #expect(try UpdateChecksum.parse("\(Self.hex)  \(name)\n", expectedFileName: name) == Self.hex)
        #expect(try UpdateChecksum.parse("\(Self.hex) *\(name)", expectedFileName: name) == Self.hex)
        #expect(try UpdateChecksum.parse("\(Self.hex.uppercased())\t\(name)\r\n", expectedFileName: name) == Self.hex)
    }

    @Test(
        "壊れた行は受け付けない（名前違い・2 行・短い・16 進でない・名前なし・空）",
        arguments: [
            "\(String(repeating: "0123456789abcdef", count: 4))  Makurip-0.1.0.zip",
            "\(String(repeating: "0123456789abcdef", count: 4))  Makurip-0.2.0.zip\n\(String(repeating: "0", count: 64))  Makurip-0.2.0.zip",
            "0123  Makurip-0.2.0.zip",
            "\(String(repeating: "g", count: 64))  Makurip-0.2.0.zip",
            String(repeating: "0123456789abcdef", count: 4),
            "",
            "\n\n",
        ])
    func rejects(_ text: String) {
        #expect(throws: UpdateFailure.checksumFileInvalid) {
            try UpdateChecksum.parse(text, expectedFileName: "Makurip-0.2.0.zip")
        }
    }

    @Test("ファイルの sha256")
    func fileHash() throws {
        let folder = TemporaryDirectory()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appendingPathComponent("a.bin")
        try Data("abc".utf8).write(to: file)
        #expect(
            try UpdateChecksum.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite("アップデート: 配信元と、確かめを緩める口")
struct UpdatePolicyTests {
    @Test("配信元の差し替えは --data-dir で隔離したときだけ効く")
    func overrideNeedsIsolation() {
        let production = UpdateSource.resolve(override: "file:///tmp/feed.json", isolated: false)
        #expect(production.source == .production)
        #expect(production.ignoredOverride)
        let isolated = UpdateSource.resolve(override: "file:///tmp/feed.json", isolated: true)
        #expect(isolated.source.overridden)
        #expect(isolated.source.feedURL.absoluteString == "file:///tmp/feed.json")
        #expect(!isolated.ignoredOverride)
        #expect(UpdateSource.resolve(override: nil, isolated: true).source == .production)
        #expect(UpdateSource.resolve(override: "/tmp/feed.json", isolated: true).source.feedURL.isFileURL)
        // 形の分からない値は使わない（本番を見る）
        #expect(UpdateSource.resolve(override: "ftp://example.com/x", isolated: true).source == .production)
    }

    @Test("本番の配信元は GitHub の Release のダウンロードの場所だけを落とす")
    func productionDownloads() throws {
        let source = UpdateSource.production
        #expect(source.feedURL.absoluteString.hasPrefix("https://api.github.com/repos/takushio2525/makurip/releases"))
        let ok = "https://github.com/takushio2525/makurip/releases/download/v0.2.0/Makurip-0.2.0.zip"
        #expect(source.allowsDownload(from: try #require(URL(string: ok))))
        for bad in [
            "http://github.com/takushio2525/makurip/releases/download/v0.2.0/Makurip-0.2.0.zip",
            "https://github.com/someone/makurip/releases/download/v0.2.0/Makurip-0.2.0.zip",
            "https://example.com/takushio2525/makurip/releases/download/v0.2.0/Makurip-0.2.0.zip",
            "https://github.com.example.com/takushio2525/makurip/releases/download/v0.2.0/Makurip-0.2.0.zip",
            "https://user:pass@github.com/takushio2525/makurip/releases/download/v0.2.0/Makurip-0.2.0.zip",
            "file:///tmp/Makurip-0.2.0.zip",
        ] {
            #expect(!source.allowsDownload(from: try #require(URL(string: bad))), "\(bad)")
        }
        let overridden = UpdateSource.resolve(override: "file:///tmp/feed.json", isolated: true).source
        #expect(overridden.allowsDownload(from: URL(fileURLWithPath: "/tmp/Makurip-0.2.0.zip")))
    }

    @Test("公証の確かめを外せるのは、隔離・差し替え・--update-allow-unnotarized の 3 つがそろったときだけ")
    func notarizationCannotBeRelaxedInProduction() {
        for isolated in [false, true] {
            for override in [nil, "file:///tmp/feed.json"] {
                for allow in [false, true] {
                    let source = UpdateSource.resolve(override: override, isolated: isolated).source
                    let policy = UpdatePolicy.resolve(isolated: isolated, source: source, allowUnnotarized: allow)
                    let relaxed = isolated && override != nil && allow
                    #expect(
                        policy.requireNotarization == !relaxed,
                        "isolated=\(isolated) override=\(override ?? "-") allow=\(allow)")
                }
            }
        }
        // 本番の配信元のままなら、隔離して許しても外れない
        #expect(UpdatePolicy.resolve(isolated: true, source: .production, allowUnnotarized: true) == .production)
    }
}

@Suite("アップデート: 署名の判断")
struct UpdateVerificationTests {
    static let current = CodeIdentity(
        bundleID: "com.takushio2525.makurip", version: "0.1.0", teamID: "TEAM1", designatedRequirement: "req-1",
        signatureValid: true, notarized: true)
    static var candidate: CodeIdentity {
        var identity = current
        identity.version = "0.2.0"
        return identity
    }

    static func check(
        _ candidate: CodeIdentity, satisfies: Bool = true, current: CodeIdentity = current,
        policy: UpdatePolicy = .production
    ) -> UpdateFailure? {
        UpdateVerification.check(
            candidate: candidate, satisfiesCurrentRequirement: satisfies, current: current,
            expected: AppVersion(major: 0, minor: 2, patch: 0), running: AppVersion(major: 0, minor: 1, patch: 0),
            policy: policy)
    }

    @Test("同じバンドル ID・チーム・要件で、公証済みの新しい版なら通す")
    func accepts() {
        #expect(Self.check(Self.candidate) == nil)
    }

    @Test("署名・バンドル ID・チーム・要件・公証・版のどれかが違えば断る")
    func rejects() {
        var c = Self.candidate
        c.signatureValid = false
        #expect(Self.check(c) == .signatureInvalid)

        c = Self.candidate
        c.bundleID = "com.example.other"
        #expect(Self.check(c) == .bundleIDMismatch)

        c = Self.candidate
        c.teamID = "TEAM2"
        #expect(Self.check(c) == .teamMismatch)
        c.teamID = nil  // アドホック署名
        #expect(Self.check(c) == .teamMismatch)

        c = Self.candidate
        c.designatedRequirement = "req-2"  // 開発用の証明書など
        #expect(Self.check(c) == .requirementMismatch)
        #expect(Self.check(Self.candidate, satisfies: false) == .requirementMismatch)

        c = Self.candidate
        c.notarized = false
        #expect(Self.check(c) == .notNotarized)

        c = Self.candidate
        c.version = "0.3.0"
        #expect(Self.check(c) == .versionMismatch(expected: "0.2.0", found: "0.3.0"))
        c.version = nil
        #expect(Self.check(c) == .versionMismatch(expected: "0.2.0", found: nil))
    }

    @Test("公証を外すのは緩めた方針のときだけで、ほかの確かめは外れない")
    func relaxedPolicyKeepsOtherChecks() {
        let relaxed = UpdatePolicy.resolve(
            isolated: true, source: UpdateSource.resolve(override: "/tmp/f.json", isolated: true).source,
            allowUnnotarized: true)
        var c = Self.candidate
        c.notarized = false
        #expect(Self.check(c, policy: relaxed) == nil)
        c.teamID = "TEAM2"
        #expect(Self.check(c, policy: relaxed) == .teamMismatch)
        c = Self.candidate
        c.notarized = false
        c.designatedRequirement = "req-2"
        #expect(Self.check(c, policy: relaxed) == .requirementMismatch)
    }

    @Test("今の版に署名がなければ、比べられないので断る")
    func currentUnsigned() {
        var current = Self.current
        current.teamID = nil
        #expect(Self.check(Self.candidate, current: current) == .currentUnsigned)
        current = Self.current
        current.signatureValid = false
        #expect(Self.check(Self.candidate, current: current) == .currentUnsigned)
    }
}

@Suite("アップデート: AI の口から更新できない")
struct UpdateAIExclusionTests {
    @Test("MCP の道具にも --ai の命令にも、更新・版の確かめは無い")
    @MainActor
    func noUpdateTools() {
        let words = ["update", "upgrade", "release", "version", "install", "apply"]
        for tool in AITools.tools {
            let name = tool.name.lowercased()
            #expect(!words.contains { name.contains($0) }, "\(tool.name)")
        }
        for command in AICLI.commands.keys {
            #expect(!words.contains { command.lowercased().contains($0) }, "\(command)")
        }
    }

    @Test("--ai に update を渡しても、知らない命令として断る")
    @MainActor
    func aiCLIRejectsUpdate() throws {
        let ai = try AIHarness(client: nil)
        let cli = AICLI(tools: ai.tools, command: "Makurip --ai", readStandardInput: { nil })
        for verb in ["update", "apply", "check"] {
            let output = cli.run([verb])
            #expect(output.exitCode != 0, "\(verb)")
        }
    }
}
