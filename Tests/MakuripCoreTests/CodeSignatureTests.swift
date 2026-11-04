import Foundation
import Testing

@testable import MakuripCore

/// 本物の署名の読み取り（Security.framework）。証明書は使わず、アドホック署名（`codesign -s -`）の小さな .app で確かめる。
/// Developer ID で署名して公証した 2 つの版での確かめは、隔離 E2E（`scripts/e2e/update.sh`）で行う
@Suite("アップデート: 署名の読み取り")
struct CodeSignatureTests {
    /// /usr/bin/true を実行ファイルにした .app を作り、アドホック署名する
    static func makeSignedApp(in folder: URL, name: String = "Probe", identifier: String, version: String = "1.0.0")
        throws -> URL
    {
        let app = folder.appendingPathComponent("\(name).app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
        ]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent(name))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments.joined(separator: " "))")
    }

    @Test("アドホック署名の .app: 署名は通るが、チーム ID がなく公証もない")
    func adHoc() throws {
        let folder = TemporaryDirectory()
        let app = try Self.makeSignedApp(in: folder.url, identifier: "com.example.probe", version: "1.2.3")
        let identity = CodeSignature.identity(ofBundle: app)
        #expect(identity.signatureValid)
        #expect(identity.bundleID == "com.example.probe")
        #expect(identity.version == "1.2.3")
        #expect(identity.teamID == nil)
        #expect(identity.designatedRequirement != nil)
        #expect(!identity.notarized)
        // 自分の要件は満たす
        #expect(CodeSignature.satisfies(app, requirement: try #require(identity.designatedRequirement)))
    }

    @Test("署名の後に中身を書き換えた .app は、署名が通らず、元の要件も満たさない")
    func tampered() throws {
        let folder = TemporaryDirectory()
        let app = try Self.makeSignedApp(in: folder.url, identifier: "com.example.probe")
        let requirement = try #require(CodeSignature.identity(ofBundle: app).designatedRequirement)
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let info = try #require(NSMutableDictionary(contentsOf: plist))
        info["CFBundleShortVersionString"] = "9.9.9"
        try info.write(to: plist)
        let identity = CodeSignature.identity(ofBundle: app)
        #expect(!identity.signatureValid)
        #expect(!CodeSignature.satisfies(app, requirement: requirement))
    }

    @Test("封の外にファイルを足した .app は、厳しい確かめに通らない")
    func extraFile() throws {
        let folder = TemporaryDirectory()
        let app = try Self.makeSignedApp(in: folder.url, identifier: "com.example.probe")
        try Data("x".utf8).write(to: app.appendingPathComponent("Contents/MacOS/extra"))
        #expect(!CodeSignature.identity(ofBundle: app).signatureValid)
    }

    @Test("署名のない .app・別の識別子の .app は、今の版の要件を満たさない")
    func otherApps() throws {
        let folder = TemporaryDirectory()
        let current = try Self.makeSignedApp(in: folder.url, name: "Current", identifier: "com.example.probe")
        let requirement = try #require(CodeSignature.identity(ofBundle: current).designatedRequirement)
        let other = try Self.makeSignedApp(in: folder.url, name: "Other", identifier: "com.example.other")
        #expect(!CodeSignature.satisfies(other, requirement: requirement))

        let unsigned = folder.url.appendingPathComponent("Unsigned.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unsigned.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.example.probe", "CFBundleExecutable": "Unsigned"]
        try info.write(to: unsigned.appendingPathComponent("Contents/Info.plist"))
        let identity = CodeSignature.identity(ofBundle: unsigned)
        #expect(!identity.signatureValid)
        #expect(identity.designatedRequirement == nil || !CodeSignature.satisfies(unsigned, requirement: requirement))
        #expect(!CodeSignature.satisfies(unsigned, requirement: requirement))
    }

    @Test("本物の確かめでも、アドホック署名の版から別のアドホック署名の版へは置き換えない（チーム ID がない）")
    func systemReaderRejectsAdHoc() async throws {
        let folder = TemporaryDirectory()
        let applications = folder.url.appendingPathComponent("Applications", isDirectory: true)
        let installed = try Self.makeSignedApp(
            in: applications, name: "Makurip", identifier: "com.takushio2525.makurip", version: "0.1.0")
        let work = folder.url.appendingPathComponent("work", isDirectory: true)
        let candidate = try Self.makeSignedApp(
            in: work, name: "Makurip", identifier: "com.takushio2525.makurip", version: "0.2.0")
        let archive = folder.url.appendingPathComponent("Makurip-0.2.0.zip")
        try UpdateBench.zip(candidate, to: archive)
        let sha = folder.url.appendingPathComponent("Makurip-0.2.0.zip.sha256")
        try Data("\(try UpdateChecksum.sha256(of: archive))  Makurip-0.2.0.zip\n".utf8).write(to: sha)
        let source = UpdateSource.resolve(override: folder.url.appendingPathComponent("feed.json").path, isolated: true)
            .source
        // 公証を外した方針でも、チーム ID・要件の確かめは外れない
        let updater = Updater(
            source: source, policy: UpdatePolicy.resolve(isolated: true, source: source, allowUnnotarized: true),
            transport: URLSessionUpdateTransport(userAgent: "test"), stateFile: UpdateStateFile(directory: folder.url))
        let release = UpdateRelease(
            version: AppVersion(major: 0, minor: 2, patch: 0), tag: "v0.2.0", pageURL: nil, publishedAt: nil,
            archive: ReleaseAsset(name: "Makurip-0.2.0.zip", url: archive, size: nil, sha256: nil),
            checksum: ReleaseAsset(name: "Makurip-0.2.0.zip.sha256", url: sha, size: nil, sha256: nil))
        do {
            try await updater.install(release, replacing: installed, running: AppVersion(major: 0, minor: 1, patch: 0))
            Issue.record("チーム ID のない版で置き換えた")
        } catch {
            #expect(error as? UpdateFailure == .currentUnsigned)
        }
        #expect(CodeSignature.identity(ofBundle: installed).version == "0.1.0")
    }
}
