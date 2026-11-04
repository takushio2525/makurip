import Foundation
import Testing

@testable import MakuripCore

@Suite("アップデート: --update の CLI")
struct UpdateCLITests {
    final class Calls: @unchecked Sendable {
        var notified = 0
        var progress: [String] = []
        let lock = NSLock()
        func add(_ line: String) { lock.withLock { progress.append(line) } }
        func notify() { lock.withLock { notified += 1 } }
    }

    static func cli(
        _ bench: UpdateBench, running: String? = "0.1.0", appRunning: Bool = false, ignoredOverride: Bool = false,
        calls: Calls = Calls()
    ) -> UpdateCLI {
        UpdateCLI(
            updater: bench.updater(),
            environment: UpdateCLI.Environment(
                running: running.flatMap(AppVersion.init), appURL: bench.installed, autoCheck: true,
                appRunning: { appRunning }, notifyInstalled: { calls.notify() }, progress: { calls.add($0) },
                ignoredOverride: ignoredOverride))
    }

    static func json(_ output: UpdateCLI.Output) throws -> [String: JSONValue] {
        try #require(JSONValue.parse(output.stdout)?.objectValue)
    }

    @Test("status は問い合わせずに、今の版・置き場所・自動の確認・最後の結果を出す")
    func status() async throws {
        let bench = try UpdateBench()
        let output = await Self.cli(bench).run(["status", "--json"])
        #expect(output.exitCode == 0)
        let root = try Self.json(output)
        #expect(root["currentVersion"] == .string("0.1.0"))
        #expect(root["installable"] == .bool(true))
        #expect(root["autoCheck"] == .bool(true))
        #expect(root["feed"] == .string("github"))
        #expect(root["notarizationRequired"] == .bool(true))
        #expect(root["available"] == .bool(false))
        #expect(bench.transport.requested.isEmpty, "status は問い合わせない")
        let text = await Self.cli(bench).run(["status"])
        #expect(text.stdout.contains("Makurip 0.1.0"))
        #expect(text.stdout.contains("自動の確認: オン"))
        // チーム ID・要件の中身は出さない
        #expect(!text.stdout.contains(UpdateBench.team) && !text.stdout.contains(UpdateBench.requirement))
    }

    @Test("check は新しい版の有無を出し、入れ替えない")
    func check() async throws {
        let bench = try UpdateBench()
        bench.transport.responses[UpdateSource.production.feedURL] = FeedFixture.data([FeedFixture.release("0.2.0")])
        let output = await Self.cli(bench).run(["check", "--json"])
        #expect(output.exitCode == 0)
        let root = try Self.json(output)
        #expect(root["result"] == .string("available"))
        #expect(root["latestVersion"] == .string("0.2.0"))
        #expect(bench.installedVersion == "0.1.0")
        let text = await Self.cli(bench).run(["check"])
        #expect(text.stdout.contains("新しい版 v0.2.0 があります"))
    }

    @Test("通信できなければ check は終了コード 3 と理由")
    func checkFailure() async throws {
        let bench = try UpdateBench()
        bench.transport.failing = [UpdateSource.production.feedURL]
        let output = await Self.cli(bench).run(["check"])
        #expect(output.exitCode == 3)
        #expect(output.stderr.contains("つながらない"))
    }

    @Test("apply は落として確かめて置き換え、動いている Makurip に起動し直しを頼む")
    func apply() async throws {
        let bench = try UpdateBench()
        let release = try bench.publish("0.2.0")
        bench.transport.responses[UpdateSource.production.feedURL] = FeedFixture.data([FeedFixture.entry(release)])
        let calls = Calls()
        let output = await Self.cli(bench, appRunning: true, calls: calls).run(["apply", "--json"])
        #expect(output.exitCode == 0, "\(output.stdout)\(output.stderr)")
        let root = try Self.json(output)
        #expect(root["result"] == .string("installed"))
        #expect(root["version"] == .string("0.2.0"))
        #expect(root["relaunching"] == .bool(true))
        #expect(calls.notified == 1)
        #expect(calls.progress.contains("ダウンロード…"))
        #expect(bench.installedVersion == "0.2.0")
    }

    @Test("apply で確かめに通らなければ終了コード 2 と理由、今の版のまま")
    func applyRejected() async throws {
        let bench = try UpdateBench()
        let release = try bench.publish(
            "0.2.0", checksumLine: { _ in "\(String(repeating: "0", count: 64))  Makurip-0.2.0.zip\n" })
        bench.transport.responses[UpdateSource.production.feedURL] = FeedFixture.data([FeedFixture.entry(release)])
        let calls = Calls()
        let output = await Self.cli(bench, appRunning: true, calls: calls).run(["apply"])
        #expect(output.exitCode == 2)
        #expect(output.stderr.contains("sha256"))
        #expect(calls.notified == 0)
        bench.expectUntouched()
        #expect(bench.updater().stateFile.load().lastError?.contains("sha256") == true)
    }

    @Test("新しい版がなければ apply は何もしない（prerelease だけのときも）")
    func applyUpToDate() async throws {
        let bench = try UpdateBench()
        bench.transport.responses[UpdateSource.production.feedURL] = FeedFixture.data([
            FeedFixture.release("0.1.0"), FeedFixture.release("0.2.0", prerelease: true),
        ])
        let output = await Self.cli(bench).run(["apply"])
        #expect(output.exitCode == 0)
        #expect(output.stdout.contains("最新"))
        #expect(bench.installedVersion == "0.1.0")
    }

    @Test("--update-feed を --data-dir なしで付けたら、check・apply は止める")
    func ignoredOverride() async throws {
        let bench = try UpdateBench()
        for verb in ["check", "apply"] {
            let output = await Self.cli(bench, ignoredOverride: true).run([verb])
            #expect(output.exitCode == 1)
            #expect(output.stderr.contains("--data-dir"))
        }
        #expect(bench.transport.requested.isEmpty)
        let status = await Self.cli(bench, ignoredOverride: true).run(["status"])
        #expect(status.exitCode == 0)
        #expect(status.stderr.contains("--data-dir"))
    }

    @Test("使い方の誤りは終了コード 1")
    func usage() async throws {
        let bench = try UpdateBench()
        #expect(await Self.cli(bench).run([]).exitCode == 1)
        #expect(await Self.cli(bench).run(["install"]).exitCode == 1)
        #expect(await Self.cli(bench).run(["check", "extra"]).exitCode == 1)
        #expect(await Self.cli(bench).run(["help"]).exitCode == 0)
    }
}
