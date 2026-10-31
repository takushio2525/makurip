import Foundation

/// データフォルダの決め方と、同じフォルダを 2 つのインスタンスが使わないためのロック
public enum DataDirectory {
    /// 既定: `~/Library/Application Support/<バンドル ID>/`
    public static func defaultURL(bundleID: String) -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    /// 起動引数 `--data-dir` → 環境変数 `MAKURIP_DATA_DIR` → 既定、の順で決める。
    /// 戻り値の `isolated` は、既定以外（検証用に隔離したフォルダ）なら true。
    /// 既定と同じ場所を明示したときは false（本物の履歴で検証用の遠隔操作を有効にしないため）
    public static func resolve(argument: String?, environment: [String: String], bundleID: String)
        -> (url: URL, isolated: Bool)
    {
        let fallback = defaultURL(bundleID: bundleID).standardizedFileURL
        if let path = argument ?? environment["MAKURIP_DATA_DIR"], !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            return (url, url.resolvingSymlinksInPath().path != fallback.resolvingSymlinksInPath().path)
        }
        return (fallback, false)
    }
}

/// データフォルダの排他ロック（`flock`）。持っているあいだ、同じフォルダで 2 つ目のインスタンスは起動できない
public final class InstanceLock {
    public static let fileName = "instance.lock"
    private let descriptor: Int32

    /// 取れなければ nil（他のインスタンスが使っている）。
    /// AI の口（`AppPresence`）が一瞬だけ共有のロックを取って確かめることがあるので、少し待ちながら数回試す
    public init?(directory: URL, attempts: Int = 10) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(Self.fileName).path
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        var locked = false
        for attempt in 0..<max(1, attempts) {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            if attempt + 1 < attempts { usleep(30_000) }
        }
        guard locked else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// 同じデータフォルダで Makurip（アプリ）が動いているか。アプリが持つ `instance.lock` の排他ロックを、共有のロックで試して確かめる
/// （取れたら動いていないので、すぐ放す）。ロックのファイルがなければ動いていない（ファイルを作らない）
public enum AppPresence {
    public static func isRunning(directory: URL) -> Bool {
        let path = directory.appendingPathComponent(InstanceLock.fileName).path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
