import Foundation

/// 動いているアプリの定型文。ファイルから読み、変化（AI の口・手での書き換え）を見て読み直し、変わったら知らせる。
///
/// 定型文の窓・一覧からの変更もここを通す（検証 → ファイルに書く → 知らせる）。検証は `SnippetCollection` の 1 か所。
/// 監視の仕組みは `SettingsController` と同じ（データフォルダと、ファイルそのものの 2 つ。中身が同じなら知らせない）
@MainActor
public final class SnippetController {
    public let file: SnippetFile
    public private(set) var collection: SnippetCollection
    /// 読めなかった項目の理由
    public private(set) var issues: [String]
    /// ファイルから読み直して変わった回数（検証の状態出力に使う）
    public private(set) var reloadCount = 0
    public var clock: () -> Date = Date.init
    private var needsBackup: Bool
    private var lastData: Data?
    private var observers: [UUID: @MainActor (SnippetCollection) -> Void] = [:]
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    public var reloadDelay: TimeInterval = 0.05

    public init(file: SnippetFile) {
        self.file = file
        let data = try? Data(contentsOf: file.url)
        let contents = data.map { SnippetFile.decode($0, now: Date()) } ?? .empty
        collection = contents.collection
        issues = contents.issues
        needsBackup = contents.needsBackup
        lastData = data
    }

    public var snippets: [Snippet] { collection.snippets }

    // MARK: 知らせる

    @discardableResult
    public func observe(_ handler: @escaping @MainActor (SnippetCollection) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func update(to contents: SnippetFile.Contents, data: Data?) {
        let old = collection
        collection = contents.collection
        issues = contents.issues
        needsBackup = contents.needsBackup
        lastData = data
        guard old != collection else { return }
        for handler in observers.values { handler(collection) }
    }

    // MARK: 変える

    // どれも書く前にファイルを読み直す（外の AI の口・手が書いてから監視が読み直すまでの間や、見張りが外れているときに、
    // 手元の古い値で外の変更を消さないため。編集中のものが外で消されていれば、その時点で知らせて「ない」と断る）

    @discardableResult
    public func add(_ draft: SnippetDraft, at index: Int? = nil) throws -> Snippet {
        reload()
        var next = collection
        let snippet = try next.add(draft, at: index, now: clock())
        try write(next)
        return snippet
    }

    @discardableResult
    public func update(id: UUID, with draft: SnippetDraft) throws -> Snippet {
        reload()
        var next = collection
        let snippet = try next.update(id: id, with: draft, now: clock())
        if next != collection { try write(next) }
        return snippet
    }

    @discardableResult
    public func remove(id: UUID) throws -> Snippet {
        reload()
        var next = collection
        let snippet = try next.remove(id: id)
        try write(next)
        return snippet
    }

    public func move(id: UUID, to index: Int) throws {
        reload()
        var next = collection
        try next.move(id: id, to: index)
        if next != collection { try write(next) }
    }

    @discardableResult
    public func move(id: UUID, by delta: Int) throws -> Bool {
        reload()
        var next = collection
        guard try next.move(id: id, by: delta) else { return false }
        try write(next)
        return true
    }

    private func write(_ next: SnippetCollection) throws {
        try file.save(next, backingUp: needsBackup)
        let data = try? Data(contentsOf: file.url)
        update(to: data.map { SnippetFile.decode($0, now: clock()) } ?? .empty, data: data)
    }

    // MARK: 読み直す

    /// ファイルを読み直す。中身が前と同じなら何もしない。変わっていれば true
    @discardableResult
    public func reload() -> Bool {
        let data = try? Data(contentsOf: file.url)
        guard data != lastData else { return false }
        let before = collection
        update(to: data.map { SnippetFile.decode($0, now: clock()) } ?? .empty, data: data)
        if before != collection { reloadCount += 1 }
        return before != collection
    }

    public func startWatching() {
        stopWatching()
        try? FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        directorySource = makeSource(path: file.directory.path, events: .write)
        armFileSource()
    }

    public func stopWatching() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        pendingReload?.cancel()
        pendingReload = nil
    }

    public var isWatching: Bool { directorySource != nil }

    /// ファイルは置き換えのたびに別物になるので、変化のたびに付け直す
    private func armFileSource() {
        fileSource?.cancel()
        fileSource = makeSource(path: file.url.path, events: [.write, .extend, .delete, .rename])
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fileSystemDidChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func fileSystemDidChange() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.armFileSource()
                self.reload()
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reloadDelay, execute: work)
    }
}
