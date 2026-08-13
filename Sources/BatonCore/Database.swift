import Foundation
import SQLite3

/// A small SQLite3 wrapper. The package keeps zero external dependencies.
final class Database {
    enum Error: Swift.Error, CustomStringConvertible {
        case open(String)
        case prepare(String, String)
        case step(String, String)

        var description: String {
            switch self {
            case .open(let msg): return "sqlite open failed: \(msg)"
            case .prepare(let sql, let msg): return "sqlite prepare failed: \(msg) — \(sql)"
            case .step(let sql, let msg): return "sqlite step failed: \(msg) — \(sql)"
            }
        }
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            handle = nil
            throw Error.open(message)
        }
        // Wait instead of failing when another process holds the write lock.
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private var errorMessage: String {
        guard let handle else { return "no handle" }
        return String(cString: sqlite3_errmsg(handle))
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw Error.step(sql, message)
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ bindings: [Value] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw Error.step(sql, errorMessage)
        }
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ bindings: [Value] = [], _ map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                results.append(try map(Row(statement: statement)))
            } else if code == SQLITE_DONE {
                break
            } else {
                throw Error.step(sql, errorMessage)
            }
        }
        return results
    }

    /// Wraps work in an immediate transaction so cross-process writes serialise.
    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try work()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = errorMessage
            sqlite3_finalize(statement)
            throw Error.prepare(sql, message)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let number):
                sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                sqlite3_bind_double(statement, index, number)
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            }
        }
        return statement
    }

    // MARK: - Values

    enum Value {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)

        static func text(_ value: String?) -> Value {
            guard let value else { return .null }
            return .text(value)
        }

        static func date(_ value: Date?) -> Value {
            guard let value else { return .null }
            return .real(value.timeIntervalSince1970)
        }

        static func int(_ value: Int?) -> Value {
            guard let value else { return .null }
            return .integer(Int64(value))
        }
    }

    struct Row {
        let statement: OpaquePointer?

        func string(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        }

        func int(_ index: Int32) -> Int64? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement, index)
        }

        func double(_ index: Int32) -> Double? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(statement, index)
        }

        func date(_ index: Int32) -> Date? {
            guard let seconds = double(index) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }
}

// The transient destructor tells SQLite to copy the bound string.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
