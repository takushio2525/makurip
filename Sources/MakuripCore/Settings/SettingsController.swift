import Foundation

/// 動いているアプリの設定。ファイルから読み、ファイルの変化（CLI・AI・手での書き換え）を見て読み直し、変わったら知らせる。
///
/// 画面からの変更もここを通す（`set` → 検証 → ファイルに書く → 知らせる）。CLI は別のプロセスなので
/// `SettingsCLI` が同じ `SettingsSchema` と `SettingsFile` で書き、こちらはファイルの変化で知る。
///
/// 監視はデータフォルダ（置き換えで書かれたときに名前が変わる）と、設定ファイルそのもの（その場で書き換えたとき）の 2 つ。
/// 同じ中身なら知らせない（自分で書いたときも、ファイルの変化で 1 回読み直すが、中身が同じなので知らせない）
@MainActor
public final class SettingsController {
    public let file: SettingsFile
    public private(set) var settings: AppSettings
    /// 読めなかった・使わなかった項目の理由
    public private(set) var issues: [SettingsError]
    /// ファイルから読み直して変わった回数（検証の状態出力に使う）
    public private(set) var reloadCount = 0
    private var unknown: [String: JSONValue]
    private var broken: Bool
    private var lastData: Data?
    private var observers: [UUID: @MainActor (AppSettings, AppSettings) -> Void] = [:]
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    /// ファイルの変化から読み直すまでの待ち（置き換えの途中を読まないように、続けて来た変化をまとめる）
    public var reloadDelay: TimeInterval = 0.05

    public init(file: SettingsFile) {
        self.file = file
        let data = try? Data(contentsOf: file.url)
        let contents = data.map(SettingsFile.decode) ?? .empty
        settings = contents.settings
        issues = contents.issues
        unknown = contents.unknown
        broken = contents.broken
        lastData = data
    }

    // MARK: 知らせる

    /// 変わったときに呼ぶ（新しい設定・前の設定）。戻り値で外せる
    @discardableResult
    public func observe(_ handler: @escaping @MainActor (AppSettings, AppSettings) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func update(to contents: SettingsFile.Contents, data: Data?) {
        let old = settings
        settings = contents.settings
        issues = contents.issues
        unknown = contents.unknown
        broken = contents.broken
        lastData = data
        guard old != settings else { return }
        for handler in observers.values { handler(settings, old) }
    }

    // MARK: 読み直す

    /// ファイルを読み直す。中身が前と同じなら何もしない。変わっていれば true
    @discardableResult
    public func reload() -> Bool {
        let data = try? Data(contentsOf: file.url)
        guard data != lastData else { return false }
        let before = settings
        update(to: data.map(SettingsFile.decode) ?? .empty, data: data)
        if before != settings { reloadCount += 1 }
        return before != settings
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

    // MARK: 変える（設定画面から）

    /// 値を検証して入れ、ファイルに書く。外した操作（キーを付け替えたとき）を返す。
    /// 書く前にファイルを読み直す（外の CLI・AI の口が書いてから監視が読み直すまでの間や、見張りが外れているときに、
    /// 手元の古い値で外の変更を消さないため。キーの重なりも読み直した値で判定する）
    @discardableResult
    public func set(_ id: String, _ raw: JSONValue, keyConflicts: KeyConflictPolicy = .reject) throws -> [KeyAction] {
        reload()
        let change = try SettingsSchema.applying(raw, to: id, in: settings, keyConflicts: keyConflicts).get()
        try write(change.settings)
        return change.movedFrom
    }

    /// 1 つを既定に戻す
    public func reset(_ id: String) throws {
        guard let value = SettingsSchema.defaultValue(id) else {
            throw SettingsError(id: id, message: "そういう設定項目はない")
        }
        try set(id, value, keyConflicts: .allow)
    }

    /// すべて既定に戻す（知らない項目は残す。残す分を最新にするため、書く前に読み直す）
    public func resetAll() throws {
        reload()
        try write(.default)
    }

    private func write(_ next: AppSettings) throws {
        try file.save(next, unknown: unknown, backingUpBroken: broken)
        let data = try? Data(contentsOf: file.url)
        update(to: data.map(SettingsFile.decode) ?? .empty, data: data)
    }
}
