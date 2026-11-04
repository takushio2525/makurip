import Foundation
import Testing

@testable import MakuripCore

/// 偽の署名。.app の中の `Contents/Resources/fake-signature.json`（チーム・要件・署名の可否・公証）を読む。
/// 置き換えの流れ（落とす・照らす・展開・判断・置き換え）を、本物の証明書なしで試すためのもの
struct FakeSignatureReader: SignatureReading {
    struct Marker: Codable {
        var team: String?
        var requirement: String?
        var valid = true
        var notarized = true
    }

    static func write(_ marker: Marker, into app: URL) throws {
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(marker).write(to: resources.appendingPathComponent("fake-signature.json"))
    }

    static func marker(of app: URL) -> Marker? {
        (try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/fake-signature.json")))
            .flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
    }

    func identity(ofBundle url: URL) -> CodeIdentity {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        let marker = Self.marker(of: url)
        return CodeIdentity(
            bundleID: info?["CFBundleIdentifier"] as? String, version: info?["CFBundleShortVersionString"] as? String,
            teamID: marker?.team, designatedRequirement: marker?.requirement, signatureValid: marker?.valid ?? false,
            notarized: marker?.notarized ?? false)
    }

    func satisfies(_ candidate: URL, requirement: String) -> Bool {
        Self.marker(of: candidate)?.requirement == requirement && Self.marker(of: candidate)?.valid == true
    }
}

/// 偽の通信。URL ごとの中身を返すか、通信の失敗を投げる
final class FakeTransport: UpdateTransport, @unchecked Sendable {
    var responses: [URL: Data] = [:]
    var failing: Set<URL> = []
    private(set) var requested: [URL] = []
    private let lock = NSLock()

    func data(from url: URL, maxBytes: Int) async throws -> Data {
        try respond(url, maxBytes: maxBytes)
    }

    func download(from url: URL, to destination: URL, maxBytes: Int) async throws {
        try respond(url, maxBytes: maxBytes).write(to: destination)
    }

    private func respond(_ url: URL, maxBytes: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        requested.append(url)
        if failing.contains(url) { throw UpdateFailure.network("つながらない") }
        guard let data = responses[url] else { throw UpdateFailure.network("見つからない（404）") }
        guard data.count <= maxBytes else { throw UpdateFailure.tooLarge }
        return data
    }
}

/// 一時フォルダに、偽の .app・zip・Release の一覧を作る
final class UpdateBench {
    let folder = TemporaryDirectory()
    let transport = FakeTransport()
    var root: URL { folder.url }
    var installed: URL { root.appendingPathComponent("Applications/Makurip.app", isDirectory: true) }
    static let team = "TEAM1"
    static let requirement = "req-team1"

    init(installedVersion: String = "0.1.0") throws {
        try Self.makeApp(at: installed, version: installedVersion)
    }

    static func makeApp(
        at url: URL, version: String, bundleID: String = "com.takushio2525.makurip",
        marker: FakeSignatureReader.Marker = .init(team: team, requirement: requirement)
    ) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try manager.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleExecutable": "Makurip",
            "CFBundleName": "Makurip",
        ]
        try info.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data("binary-\(version)".utf8).write(to: macOS.appendingPathComponent("Makurip"))
        try FakeSignatureReader.write(marker, into: url)
    }

    /// `ditto -c -k --keepParent` で固める（配布の zip と同じ作り）
    static func zip(_ folder: URL, to archive: URL, keepParent: Bool = true) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [folder.path, archive.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    /// 新しい版の Release を作り、偽の通信に載せる。返すのは一覧の Release
    @discardableResult
    func publish(
        _ version: String, app: ((URL) throws -> Void)? = nil, checksumLine: ((String) -> String)? = nil,
        size: Int? = nil, archiveContents: ((URL) throws -> (url: URL, keepParent: Bool))? = nil
    ) throws -> UpdateRelease {
        let work = root.appendingPathComponent("build-\(version)-\(UUID().uuidString)", isDirectory: true)
        let appURL = work.appendingPathComponent("Makurip.app", isDirectory: true)
        try Self.makeApp(at: appURL, version: version)
        try app?(appURL)
        let archive = work.appendingPathComponent("Makurip-\(version).zip")
        let contents: (url: URL, keepParent: Bool) = try archiveContents?(work) ?? (appURL, true)
        try Self.zip(contents.url, to: archive, keepParent: contents.keepParent)
        let data = try Data(contentsOf: archive)
        let hex = try UpdateChecksum.sha256(of: archive)
        let line = checksumLine?(hex) ?? "\(hex)  Makurip-\(version).zip\n"
        let base = "https://github.com/takushio2525/makurip/releases/download/v\(version)"
        let zipURL = try #require(URL(string: "\(base)/Makurip-\(version).zip"))
        let shaURL = try #require(URL(string: "\(base)/Makurip-\(version).zip.sha256"))
        transport.responses[zipURL] = data
        transport.responses[shaURL] = Data(line.utf8)
        let release = UpdateRelease(
            version: try #require(AppVersion(version)), tag: "v\(version)", pageURL: nil, publishedAt: nil,
            archive: ReleaseAsset(name: "Makurip-\(version).zip", url: zipURL, size: size ?? data.count, sha256: nil),
            checksum: ReleaseAsset(name: "Makurip-\(version).zip.sha256", url: shaURL, size: nil, sha256: nil))
        return release
    }

    func updater(source: UpdateSource = .production, policy: UpdatePolicy = .production) -> Updater {
        Updater(
            source: source, policy: policy, transport: transport,
            stateFile: UpdateStateFile(directory: root.appendingPathComponent("data")),
            signatures: FakeSignatureReader())
    }

    var installedVersion: String? {
        NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"]
            as? String
    }

    var installedBinary: Data? { try? Data(contentsOf: installed.appendingPathComponent("Contents/MacOS/Makurip")) }

    /// 置き換えに失敗した後、今の版のまま・作業の残りがないか
    func expectUntouched(_ comment: Comment? = nil) {
        #expect(installedVersion == "0.1.0", comment)
        #expect(installedBinary == Data("binary-0.1.0".utf8), comment)
        let leftovers =
            (try? FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path))
            ?? []
        #expect(leftovers == ["Makurip.app"], comment)
    }
}

@Suite("アップデート: 落として確かめて置き換える流れ")
struct UpdaterInstallTests {
    static let running = AppVersion(major: 0, minor: 1, patch: 0)

    func install(_ bench: UpdateBench, _ release: UpdateRelease, updater: Updater? = nil) async -> UpdateFailure? {
        do {
            try await (updater ?? bench.updater()).install(release, replacing: bench.installed, running: Self.running)
            return nil
        } catch {
            return error as? UpdateFailure ?? .replaceFailed("\(error)")
        }
    }

    @Test("新しい版を落とし、sha256・署名を確かめて置き換える（置き場所の名前はそのまま）")
    func installs() async throws {
        let bench = try UpdateBench()
        let release = try bench.publish("0.2.0")
        let calls = UpdateCLITests.Calls()
        try await bench.updater().install(release, replacing: bench.installed, running: Self.running) { step in
            calls.add(step.rawValue)
        }
        let steps = calls.progress.compactMap(Updater.Step.init(rawValue:))
        #expect(bench.installedVersion == "0.2.0")
        #expect(bench.installedBinary == Data("binary-0.2.0".utf8))
        #expect(steps == Updater.Step.allCases)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: bench.installed.deletingLastPathComponent().path)
        #expect(siblings == ["Makurip.app"])
    }

    @Test("sha256 が一致しなければ置き換えない")
    func checksumMismatch() async throws {
        let bench = try UpdateBench()
        let release = try bench.publish(
            "0.2.0", checksumLine: { _ in "\(String(repeating: "0", count: 64))  Makurip-0.2.0.zip\n" })
        #expect(await install(bench, release) == .checksumMismatch)
        bench.expectUntouched()
    }

    @Test("sha256 のファイルが壊れていれば置き換えない")
    func checksumFileBroken() async throws {
        let bench = try UpdateBench()
        let release = try bench.publish("0.2.0", checksumLine: { hex in "\(hex)  Makurip-0.1.0.zip\n" })
        #expect(await install(bench, release) == .checksumFileInvalid)
        bench.expectUntouched()
    }

    @Test("zip の中身を書き換えたら（sha256 を合わせ直さなければ）置き換えない")
    func tamperedArchive() async throws {
        let bench = try UpdateBench()
        let release = try bench.publish("0.2.0")
        var data = try #require(bench.transport.responses[release.archive.url])
        data[data.count / 2] ^= 0xFF
        bench.transport.responses[release.archive.url] = data
        #expect(await install(bench, release) == .checksumMismatch)
        bench.expectUntouched()
    }

    @Test("Release の digest と合わなければ置き換えない")
    func digestMismatch() async throws {
        let bench = try UpdateBench()
        let published = try bench.publish("0.2.0")
        let release = UpdateRelease(
            version: published.version, tag: published.tag, pageURL: nil, publishedAt: nil,
            archive: ReleaseAsset(
                name: published.archive.name, url: published.archive.url, size: published.archive.size,
                sha256: String(repeating: "1", count: 64)),
            checksum: published.checksum)
        #expect(await install(bench, release) == .checksumMismatch)
        bench.expectUntouched()
    }

    @Test("大きさが Release の記載と違えば置き換えない")
    func sizeMismatch() async throws {
        let bench = try UpdateBench()
        let release = try bench.publish("0.2.0", size: 1)
        #expect(await install(bench, release) == .sizeMismatch)
        bench.expectUntouched()
    }

    @Test("通信に失敗したら置き換えない")
    func networkFailure() async throws {
        let bench = try UpdateBench()
        let release = try bench.publish("0.2.0")
        bench.transport.failing = [release.archive.url]
        #expect(await install(bench, release) == .network("つながらない"))
        bench.expectUntouched()
    }

    @Test("別のチーム・別の要件・署名の壊れた・公証のない .app では置き換えない")
    func signatureMismatch() async throws {
        let cases: [(FakeSignatureReader.Marker, UpdateFailure)] = [
            (.init(team: "TEAM2", requirement: UpdateBench.requirement), .teamMismatch),
            (.init(team: nil, requirement: "cdhash"), .teamMismatch),
            (.init(team: UpdateBench.team, requirement: "req-development"), .requirementMismatch),
            (.init(team: UpdateBench.team, requirement: UpdateBench.requirement, valid: false), .signatureInvalid),
            (.init(team: UpdateBench.team, requirement: UpdateBench.requirement, notarized: false), .notNotarized),
        ]
        for (marker, expected) in cases {
            let bench = try UpdateBench()
            let release = try bench.publish("0.2.0") { app in try FakeSignatureReader.write(marker, into: app) }
            #expect(await install(bench, release) == expected, "\(expected)")
            bench.expectUntouched("\(expected)")
        }
    }

    @Test("バンドル ID・中の版が違う .app では置き換えない")
    func identityMismatch() async throws {
        let bench = try UpdateBench()
        let other = try bench.publish("0.2.0") { app in
            try UpdateBench.makeApp(at: app, version: "0.2.0", bundleID: "com.example.makurip")
        }
        #expect(await install(bench, other) == .bundleIDMismatch)
        bench.expectUntouched()

        let wrongVersion = try bench.publish("0.3.0") { app in try UpdateBench.makeApp(at: app, version: "0.2.5") }
        #expect(await install(bench, wrongVersion) == .versionMismatch(expected: "0.3.0", found: "0.2.5"))
        bench.expectUntouched()
    }

    @Test("zip の中に .app がない・2 つあるときは置き換えない")
    func bundleMissing() async throws {
        let bench = try UpdateBench()
        let empty = try bench.publish(
            "0.2.0",
            archiveContents: { work in
                let folder = work.appendingPathComponent("payload", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: folder.appendingPathComponent("readme.txt"))
                return (folder, true)
            })
        #expect(await install(bench, empty) == .bundleMissing)
        bench.expectUntouched()

        // 一番上に .app が 2 つ（--keepParent なしで、2 つの .app の入ったフォルダの中身を固める）
        let two = try bench.publish(
            "0.2.0",
            archiveContents: { work in
                let folder = work.appendingPathComponent("two", isDirectory: true)
                try UpdateBench.makeApp(at: folder.appendingPathComponent("Makurip.app"), version: "0.2.0")
                try UpdateBench.makeApp(at: folder.appendingPathComponent("Other.app"), version: "0.2.0")
                return (folder, false)
            })
        #expect(await install(bench, two) == .bundleMissing)
        bench.expectUntouched()
    }

    @Test("新しくない版・本番で GitHub の外を指す URL・入れ替え済みの .app・.app でない場所では始めない")
    func preconditions() async throws {
        let bench = try UpdateBench()
        let same = try bench.publish("0.1.0")
        #expect(await install(bench, same) == .notNewer)

        let release = try bench.publish("0.2.0")
        let elsewhere = UpdateRelease(
            version: release.version, tag: release.tag, pageURL: nil, publishedAt: nil,
            archive: ReleaseAsset(
                name: release.archive.name, url: try #require(URL(string: "https://example.com/Makurip-0.2.0.zip")),
                size: nil, sha256: nil), checksum: release.checksum)
        #expect(await install(bench, elsewhere) == .downloadNotAllowed)
        #expect(bench.transport.requested.isEmpty, "断ったときは何も落とさない")

        do {
            try await bench.updater().install(
                release, replacing: bench.installed, running: AppVersion(major: 0, minor: 0, patch: 9))
            Issue.record("動いている版とディスクの版が違うのに置き換えた")
        } catch {
            #expect(error as? UpdateFailure == .alreadyReplaced)
        }
        do {
            try await bench.updater().install(
                release, replacing: bench.root.appendingPathComponent("Makurip"), running: Self.running)
            Issue.record(".app でない場所を置き換えた")
        } catch {
            #expect(error as? UpdateFailure == .notInstalledAsApp)
        }
        bench.expectUntouched()
    }

    @Test("今の版に使える署名がなければ始めない")
    func currentUnsigned() async throws {
        let bench = try UpdateBench()
        try FakeSignatureReader.write(.init(team: nil, requirement: nil, valid: false), into: bench.installed)
        let release = try bench.publish("0.2.0")
        #expect(await install(bench, release) == .currentUnsigned)
        #expect(bench.installedVersion == "0.1.0")
    }

    @Test("差し替えた配信元では file:// から落とせ、緩めた方針なら公証のない版も入れる（検証用）")
    func overriddenSource() async throws {
        let bench = try UpdateBench()
        let release = try bench.publish("0.2.0") { app in
            try FakeSignatureReader.write(
                .init(team: UpdateBench.team, requirement: UpdateBench.requirement, notarized: false), into: app)
        }
        // file:// に置き直した Release
        let feedDir = bench.root.appendingPathComponent("feed", isDirectory: true)
        try FileManager.default.createDirectory(at: feedDir, withIntermediateDirectories: true)
        let zipFile = feedDir.appendingPathComponent(release.archive.name)
        let shaFile = feedDir.appendingPathComponent(release.checksum.name)
        try #require(bench.transport.responses[release.archive.url]).write(to: zipFile)
        try #require(bench.transport.responses[release.checksum.url]).write(to: shaFile)
        let local = UpdateRelease(
            version: release.version, tag: release.tag, pageURL: nil, publishedAt: nil,
            archive: ReleaseAsset(name: release.archive.name, url: zipFile, size: nil, sha256: nil),
            checksum: ReleaseAsset(name: release.checksum.name, url: shaFile, size: nil, sha256: nil))
        let source = UpdateSource.resolve(override: feedDir.appendingPathComponent("feed.json").path, isolated: true)
            .source
        let real = Updater(
            source: source, policy: .production, transport: URLSessionUpdateTransport(userAgent: "test"),
            stateFile: UpdateStateFile(directory: bench.root), signatures: FakeSignatureReader())
        #expect(await install(bench, local, updater: real) == .notNotarized)
        bench.expectUntouched()
        let relaxed = Updater(
            source: source, policy: UpdatePolicy.resolve(isolated: true, source: source, allowUnnotarized: true),
            transport: URLSessionUpdateTransport(userAgent: "test"), stateFile: UpdateStateFile(directory: bench.root),
            signatures: FakeSignatureReader())
        #expect(await install(bench, local, updater: relaxed) == nil)
        #expect(bench.installedVersion == "0.2.0")
    }

    @Test("確かめた結果を状態のファイルに書く。失敗しても前に見つけた最新は残す")
    func checkRecordsState() async throws {
        let bench = try UpdateBench()
        let feedURL = UpdateSource.production.feedURL
        bench.transport.responses[feedURL] = FeedFixture.data([
            FeedFixture.release("0.2.0"), FeedFixture.release("0.3.0", prerelease: true),
        ])
        let updater = bench.updater()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = await updater.check(running: Self.running, now: now)
        #expect(try result.get().release?.version.description == "0.2.0")
        #expect(updater.stateFile.load().lastCheckedAt == now)
        #expect(updater.stateFile.load().latest?.version.description == "0.2.0")

        bench.transport.failing = [feedURL]
        let failed = await updater.check(running: Self.running, now: now.addingTimeInterval(60))
        #expect(throws: UpdateFailure.network("つながらない")) { try failed.get() }
        let state = updater.stateFile.load()
        #expect(state.latest?.version.description == "0.2.0")
        #expect(state.lastCheckedAt == now)
        #expect(state.lastError?.contains("つながらない") == true)

        // 同じ版しかない・古い版しかない
        bench.transport.failing = []
        bench.transport.responses[feedURL] = FeedFixture.data([FeedFixture.release("0.1.0")])
        #expect(try await updater.check(running: Self.running).get() == .upToDate)
        bench.transport.responses[feedURL] = FeedFixture.data([FeedFixture.release("0.0.9")])
        #expect(try await updater.check(running: Self.running).get() == .upToDate)
        #expect(updater.stateFile.load().lastError == nil)
    }
}
