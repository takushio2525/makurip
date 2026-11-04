import Foundation

/// 署名の読み方（本番は `CodeSignature`。テストでは偽物にして、確かめの流れだけを試す）
public protocol SignatureReading: Sendable {
    func identity(ofBundle url: URL) -> CodeIdentity
    func satisfies(_ candidate: URL, requirement: String) -> Bool
}

public struct SystemSignatureReader: SignatureReading {
    public init() {}
    public func identity(ofBundle url: URL) -> CodeIdentity { CodeSignature.identity(ofBundle: url) }
    public func satisfies(_ candidate: URL, requirement: String) -> Bool {
        CodeSignature.satisfies(candidate, requirement: requirement)
    }
}

/// アップデートの本体（確かめる・入れ替える）。アプリ（メニュー・設定画面・自動の確認）と `--update` の CLI が同じものを使う。
///
/// 入れ替えの順（#43）: Release の zip と sha256 を落とす → sha256 を照らす → 展開する → 署名を確かめる
/// （同じチーム ID・同じバンドル ID・designated requirement が今の版と同じ・公証済み）→ 今の .app を置き換える。
/// どこかで失敗したら置き換えず、理由（`UpdateFailure`）を返す。起動し直すのは呼ぶ側（アプリは `Relauncher`）
public struct Updater: Sendable {
    public enum Step: String, Sendable, CaseIterable {
        case download, verifyChecksum, extract, verifySignature, replace

        public var label: String {
            switch self {
            case .download: "ダウンロード"
            case .verifyChecksum: "sha256 の照合"
            case .extract: "展開"
            case .verifySignature: "署名の確かめ"
            case .replace: "置き換え"
            }
        }
    }

    /// Release の一覧の上限
    public static let maxFeedBytes = 2 << 20
    /// zip の上限（いまは数 MB。大きく超えるものは配っていない）
    public static let maxArchiveBytes = 300 << 20

    public let source: UpdateSource
    public let policy: UpdatePolicy
    public let transport: UpdateTransport
    public let stateFile: UpdateStateFile
    public let signatures: SignatureReading

    public init(
        source: UpdateSource, policy: UpdatePolicy, transport: UpdateTransport, stateFile: UpdateStateFile,
        signatures: SignatureReading = SystemSignatureReader()
    ) {
        self.source = source
        self.policy = policy
        self.transport = transport
        self.stateFile = stateFile
        self.signatures = signatures
    }

    // MARK: 確かめる

    /// 配信元の、入れられる最新の Release（無ければ nil）
    public func fetchLatest() async throws -> UpdateRelease? {
        let data = try await transport.data(from: source.feedURL, maxBytes: Self.maxFeedBytes)
        return try ReleaseFeed.latest(in: data)
    }

    /// 確かめて、結果を状態のファイルに書く（失敗したら前に見つけた最新は残し、理由だけ書く）
    @discardableResult
    public func check(running: AppVersion, now: Date = Date()) async -> Result<UpdateAvailability, UpdateFailure> {
        do {
            let latest = try await fetchLatest()
            let state = stateFile.update { state in
                state.lastCheckedAt = now
                state.latest = latest
                state.lastError = nil
            }
            return .success(state.availability(current: running))
        } catch {
            let failure = error as? UpdateFailure ?? .network("通信できない")
            stateFile.update { $0.lastError = failure.message }
            return .failure(failure)
        }
    }

    // MARK: 入れ替える

    /// `release` を落として確かめ、`appURL`（今の .app）を置き換える。`running` は動いている版
    public func install(
        _ release: UpdateRelease, replacing appURL: URL, running: AppVersion,
        progress: @Sendable (Step) -> Void = { _ in }
    ) async throws {
        try Self.checkLocation(appURL)
        guard release.version > running else { throw UpdateFailure.notNewer }
        let current = signatures.identity(ofBundle: appURL)
        guard current.version.flatMap(AppVersion.init) == running else { throw UpdateFailure.alreadyReplaced }
        guard current.signatureValid, current.teamID != nil, let requirement = current.designatedRequirement else {
            throw UpdateFailure.currentUnsigned
        }
        guard source.allowsDownload(from: release.archive.url), source.allowsDownload(from: release.checksum.url)
        else { throw UpdateFailure.downloadNotAllowed }

        let staging = try Self.makeStagingDirectory(near: appURL)
        defer { try? FileManager.default.removeItem(at: staging) }

        progress(.download)
        let checksumData = try await transport.data(from: release.checksum.url, maxBytes: UpdateChecksum.maxFileBytes)
        guard let checksumText = String(data: checksumData, encoding: .utf8) else {
            throw UpdateFailure.checksumFileInvalid
        }
        let expected = try UpdateChecksum.parse(checksumText, expectedFileName: release.archive.name)
        let archive = staging.appendingPathComponent(release.archive.name)
        try await transport.download(from: release.archive.url, to: archive, maxBytes: Self.maxArchiveBytes)

        progress(.verifyChecksum)
        if let size = release.archive.size, Self.fileSize(archive) != size { throw UpdateFailure.sizeMismatch }
        let actual: String
        do {
            actual = try UpdateChecksum.sha256(of: archive)
        } catch {
            throw UpdateFailure.network("落としたファイルを読めない")
        }
        guard actual == expected, release.archive.sha256 == nil || release.archive.sha256 == actual else {
            throw UpdateFailure.checksumMismatch
        }

        progress(.extract)
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try Self.extract(archive, to: extracted)
        let candidate = try Self.singleBundle(in: extracted)

        progress(.verifySignature)
        if let failure = UpdateVerification.check(
            candidate: signatures.identity(ofBundle: candidate),
            satisfiesCurrentRequirement: signatures.satisfies(candidate, requirement: requirement), current: current,
            expected: release.version, running: running, policy: policy)
        {
            throw failure
        }

        progress(.replace)
        try Self.replace(appURL, with: candidate)
    }

    /// 置き換えられる場所か（.app の中・隔離されていない・書ける）
    public static func checkLocation(_ appURL: URL) throws {
        guard appURL.pathExtension == "app" else { throw UpdateFailure.notInstalledAsApp }
        if appURL.path.contains("/AppTranslocation/") { throw UpdateFailure.translocated }
        let manager = FileManager.default
        guard manager.isWritableFile(atPath: appURL.deletingLastPathComponent().path),
            manager.isWritableFile(atPath: appURL.path)
        else { throw UpdateFailure.notWritable }
    }

    /// 作業場所。置き換えを rename 1 回で済ませるため、今の .app と同じボリュームに作る
    static func makeStagingDirectory(near appURL: URL) throws -> URL {
        let manager = FileManager.default
        if let url = try? manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        {
            return url
        }
        let sibling = appURL.deletingLastPathComponent().appendingPathComponent(
            ".makurip-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: sibling, withIntermediateDirectories: false)
        } catch {
            throw UpdateFailure.notWritable
        }
        return sibling
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    /// `ditto -x -k`（Finder の展開と同じく、署名・拡張属性を保つ）
    static func extract(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateFailure.extractFailed("ditto を起動できない")
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let line =
                String(data: output.prefix(200), encoding: .utf8)?.split(whereSeparator: \.isNewline).first.map(
                    String.init) ?? ""
            throw UpdateFailure.extractFailed(line.isEmpty ? "ditto の終了コード \(process.terminationStatus)" : line)
        }
    }

    /// 展開した中の .app（ちょうど 1 つ・本物のフォルダ）
    static func singleBundle(in directory: URL) throws -> URL {
        let entries =
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        guard entries.count == 1, let bundle = entries.first, bundle.pathExtension == "app" else {
            throw UpdateFailure.bundleMissing
        }
        let values = try? bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { throw UpdateFailure.bundleMissing }
        return bundle
    }

    /// 今の .app と新しい .app を入れ替える。同じボリュームなら `renamex_np` の RENAME_SWAP で一度に入れ替え、
    /// どの瞬間にも置き場所に .app がある（古い版は作業場所に残り、作業場所ごと消える）。
    /// swap が使えないときは、今の版を脇へ動かしてから置き、置けなければ戻す
    static func replace(_ appURL: URL, with candidate: URL) throws {
        if renamex_np(candidate.path, appURL.path, UInt32(RENAME_SWAP)) == 0 { return }
        let manager = FileManager.default
        let aside = candidate.deletingLastPathComponent().appendingPathComponent(
            "previous-\(UUID().uuidString)-" + appURL.lastPathComponent)
        do {
            try manager.moveItem(at: appURL, to: aside)
        } catch {
            throw UpdateFailure.replaceFailed("今の版を動かせない")
        }
        do {
            try manager.moveItem(at: candidate, to: appURL)
        } catch {
            try? manager.moveItem(at: aside, to: appURL)
            throw UpdateFailure.replaceFailed("新しい版を置けない")
        }
    }
}
