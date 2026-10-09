import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

struct SQLiteRow {
    private let statement: OpaquePointer

    init(statement: OpaquePointer) {
        self.statement = statement
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func bool(_ column: Int32) -> Bool { sqlite3_column_int64(statement, column) != 0 }

    func string(_ column: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: cString)
    }

    func optionalString(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    func optionalInt64(_ column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    func data(_ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: pointer, count: count)
    }
}

enum SQLiteError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String, sql: String)
    case stepFailed(String, sql: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "SQLite open failed: \(message)"
        case .prepareFailed(let message, let sql): return "SQLite prepare failed: \(message) — \(sql)"
        case .stepFailed(let message, let sql): return "SQLite step failed: \(message) — \(sql)"
        }
    }
}

/// Thin wrapper over the system libsqlite3. Not thread-safe on its own; use it
/// from a single actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError.openFailed(message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        sqlite3_close(handle)
    }

    @discardableResult
    func execute(_ sql: String) throws -> Bool {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw SQLiteError.stepFailed(message, sql: sql)
        }
        return true
    }

    func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.stepFailed(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
    }

    func query(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        _ map: (SQLiteRow) -> Void
    ) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            map(SQLiteRow(statement: statement))
        }
    }

    func queryValue<T>(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        _ transform: (SQLiteRow) -> T
    ) throws -> T? {
        var result: T?
        try query(sql, parameters) { row in
            if result == nil { result = transform(row) }
        }
        return result
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(
                handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown",
                sql: sql
            )
        }
        for (index, parameter) in parameters.enumerated() {
            let position = Int32(index + 1)
            switch parameter {
            case .null:
                sqlite3_bind_null(statement, position)
            case .integer(let value):
                sqlite3_bind_int64(statement, position, value)
            case .real(let value):
                sqlite3_bind_double(statement, position, value)
            case .text(let value):
                sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
        }
        return statement
    }
}
