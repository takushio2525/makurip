import Foundation
import SQLite3

/// macOS 同梱の SQLite（libsqlite3）の薄いラッパー。外部ライブラリを入れないために自前で持つ。
/// スレッド安全ではない。`ClipStore` がロックで守る前提。
final class SQLiteDatabase {
    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite(\(code)): \(message)" }
    }

    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw Failure(code: code, message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw Failure(code: code, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw lastError(code) }
        return SQLiteStatement(statement: statement, database: self)
    }

    /// 本体が投げたら ROLLBACK、正常に終われば COMMIT
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func lastError(_ code: Int32) -> Failure {
        Failure(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        return try statement.step() ? statement.int(0) : 0
    }
}

/// プリペアドステートメント。bind は 1 始まり、列の読み出しは 0 始まり（SQLite の流儀のまま）
final class SQLiteStatement {
    private let statement: OpaquePointer
    private let database: SQLiteDatabase
    /// bind したデータを SQLite に写させる（Swift 側のバッファが先に消えても安全なように）
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    @discardableResult
    func bind(_ values: SQLiteValue?...) throws -> SQLiteStatement {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case nil: code = sqlite3_bind_null(statement, index)
            case .int(let v): code = sqlite3_bind_int64(statement, index, Int64(v))
            case .double(let v): code = sqlite3_bind_double(statement, index, v)
            case .text(let v): code = sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .blob(let v):
                code = v.withUnsafeBytes { buffer in
                    // 空の Data は baseAddress が nil になるので、長さ 0 の zeroblob にする
                    guard let base = buffer.baseAddress else { return sqlite3_bind_zeroblob(statement, index, 0) }
                    return sqlite3_bind_blob(statement, index, base, Int32(buffer.count), Self.transient)
                }
            }
            guard code == SQLITE_OK else { throw database.lastError(code) }
        }
        return self
    }

    /// 1 行進める。行があれば true、終わりなら false
    func step() throws -> Bool {
        let code = sqlite3_step(statement)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.lastError(code)
        }
    }

    /// 結果を読まない文（INSERT / UPDATE / DELETE）を最後まで実行する
    func run() throws {
        while try step() {}
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    func blob(_ column: Int32) -> Data? {
        if isNull(column) { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}

enum SQLiteValue {
    case int(Int)
    case double(Double)
    case text(String)
    case blob(Data)
}
