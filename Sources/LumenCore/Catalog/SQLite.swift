// SQLite.swift
// A minimal, safe wrapper over the system sqlite3 C API — the only thing standing
// between LumenCore and raw pointers. Deliberately small: open/close, exec, prepare,
// typed binds, typed column reads, transactions, `PRAGMA user_version`. No ORM, no
// row mapping, no query DSL; CatalogStore owns all of that (docs/15 §15.2).
//
// Rules this file exists to enforce:
//  - every text/blob bind copies through SQLITE_TRANSIENT, so no Swift buffer is ever
//    handed to sqlite3 with a lifetime shorter than the statement;
//  - every statement is finalized (deinit) and every handle closed (deinit);
//  - errors carry the sqlite3 result code AND sqlite3_errmsg, never just "failed".
//
// Platform: `import SQLite3` is an Apple-SDK module. LumenCore also builds on Linux
// for headless verification of the pure core, so everything below is fenced and the
// Linux side is an honest stub that refuses to pretend.

#if canImport(SQLite3)

import Foundation
import SQLite3

/// sqlite3's "copy the bytes before returning" destructor sentinel. The C header
/// defines it as ((sqlite3_destructor_type)-1), which Swift cannot import.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Errors

public enum SQLiteError: Error, CustomStringConvertible {
    case unavailable
    case open(code: Int32, message: String, path: String)
    case exec(code: Int32, message: String, sql: String)
    case prepare(code: Int32, message: String, sql: String)
    case bind(code: Int32, message: String, index: Int)
    case step(code: Int32, message: String, sql: String)
    case closed(String)

    public var code: Int32 {
        switch self {
        case .unavailable, .closed: return SQLITE_MISUSE
        case .open(let c, _, _): return c
        case .exec(let c, _, _): return c
        case .prepare(let c, _, _): return c
        case .bind(let c, _, _): return c
        case .step(let c, _, _): return c
        }
    }

    /// Whether this failure means the database file is damaged, as opposed to busy or
    /// momentarily unavailable. A caller that recreates the file on anything else
    /// destroys a live database.
    ///
    /// It lives here rather than at the call site because the `SQLITE_*` codes come
    /// from the C module, and this file is the only one in LumenCore that imports it.
    public var indicatesCorruptDatabase: Bool {
        switch code {
        case SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_FORMAT: return true
        default: return false
        }
    }

    public var message: String {
        switch self {
        case .unavailable: return "SQLite is not available on this platform"
        case .closed(let what): return what
        case .open(_, let m, _): return m
        case .exec(_, let m, _): return m
        case .prepare(_, let m, _): return m
        case .bind(_, let m, _): return m
        case .step(_, let m, _): return m
        }
    }

    public var description: String {
        switch self {
        case .unavailable:
            return "sqlite3: unavailable on this platform"
        case .closed(let what):
            return "sqlite3: \(what)"
        case .open(let c, let m, let p):
            return "sqlite3 open(\(p)) failed [\(c)]: \(m)"
        case .exec(let c, let m, let sql):
            return "sqlite3 exec failed [\(c)]: \(m) — SQL: \(SQLiteError.excerpt(sql))"
        case .prepare(let c, let m, let sql):
            return "sqlite3 prepare failed [\(c)]: \(m) — SQL: \(SQLiteError.excerpt(sql))"
        case .bind(let c, let m, let i):
            return "sqlite3 bind(\(i)) failed [\(c)]: \(m)"
        case .step(let c, let m, let sql):
            return "sqlite3 step failed [\(c)]: \(m) — SQL: \(SQLiteError.excerpt(sql))"
        }
    }

    private static func excerpt(_ sql: String) -> String {
        let flat = sql.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 240 ? flat : String(flat.prefix(240)) + "…"
    }
}

// MARK: - Values

/// A bindable SQLite value. The typed `bind` overloads are the ergonomic surface;
/// this enum is what the query builder uses so a parameter list is just an array.
public enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public static func int(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
    public static func bool(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }

    public static func optionalInteger(_ value: Int64?) -> SQLiteValue {
        if let v = value { return .integer(v) }
        return .null
    }

    public static func optionalInt(_ value: Int?) -> SQLiteValue {
        if let v = value { return .integer(Int64(v)) }
        return .null
    }

    public static func optionalReal(_ value: Double?) -> SQLiteValue {
        if let v = value { return .real(v) }
        return .null
    }

    public static func optionalText(_ value: String?) -> SQLiteValue {
        if let v = value { return .text(v) }
        return .null
    }

    public static func optionalBlob(_ value: Data?) -> SQLiteValue {
        if let v = value { return .blob(v) }
        return .null
    }
}

// MARK: - Database

public final class SQLiteDatabase {

    private var handle: OpaquePointer?
    private var transactionDepth: Int = 0

    public let path: String

    public init(path: String) throws {
        self.path = path
        var raw: OpaquePointer?
        let flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &raw, flags, nil)
        if rc != SQLITE_OK {
            var message = "unable to open database"
            if let opened = raw {
                message = String(cString: sqlite3_errmsg(opened))
                _ = sqlite3_close_v2(opened)
            }
            throw SQLiteError.open(code: rc, message: message, path: path)
        }
        // sqlite3_open_v2 only reports OK with a non-nil handle; the guard is belt
        // and braces so `handle` is never an unwrapped surprise later.
        guard let opened = raw else {
            throw SQLiteError.open(code: SQLITE_ERROR, message: "null handle", path: path)
        }
        self.handle = opened
    }

    deinit {
        if let raw = handle {
            _ = sqlite3_close_v2(raw)
            handle = nil
        }
    }

    /// Close early (the maintenance slot's `PRAGMA optimize` + quit path). Idempotent.
    public func close() {
        if let raw = handle {
            _ = sqlite3_close_v2(raw)
            handle = nil
        }
    }

    public var isOpen: Bool { handle != nil }

    fileprivate var rawHandle: OpaquePointer? { handle }

    fileprivate func currentErrorMessage() -> String {
        guard let raw = handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(raw))
    }

    /// Rowid of the last successful INSERT on this connection.
    public var lastInsertRowID: Int64 {
        guard let raw = handle else { return 0 }
        return sqlite3_last_insert_rowid(raw)
    }

    /// Rows changed by the most recent INSERT/UPDATE/DELETE on this connection.
    public var changes: Int {
        guard let raw = handle else { return 0 }
        return Int(sqlite3_changes(raw))
    }

    /// Execute one or more statements. Used for DDL, pragmas and migrations, never
    /// for anything carrying user input — those go through `prepare` + binds.
    public func execute(_ sql: String) throws {
        guard let raw = handle else { throw SQLiteError.closed("execute on a closed database") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(raw, sql, nil, nil, &errorPointer)
        var message = ""
        if let err = errorPointer {
            message = String(cString: err)
            sqlite3_free(err)
        }
        if rc != SQLITE_OK {
            if message.isEmpty { message = String(cString: sqlite3_errmsg(raw)) }
            throw SQLiteError.exec(code: rc, message: message, sql: sql)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let raw = handle else { throw SQLiteError.closed("prepare on a closed database") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(raw, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            let message = String(cString: sqlite3_errmsg(raw))
            if let leftover = stmt { sqlite3_finalize(leftover) }
            throw SQLiteError.prepare(code: rc, message: message, sql: sql)
        }
        return SQLiteStatement(owner: self, stmt: prepared, sql: sql)
    }

    /// One transaction per user action (docs/15 §15.10). BEGIN IMMEDIATE takes the
    /// write lock up front so a busy_timeout wait happens here rather than mid-write.
    /// Nesting is allowed and maps onto SAVEPOINTs so helpers compose.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            let name = "lumen_sp_\(transactionDepth)"
            try execute("SAVEPOINT \(name);")
            transactionDepth += 1
            do {
                let result = try body()
                transactionDepth -= 1
                try execute("RELEASE SAVEPOINT \(name);")
                return result
            } catch {
                transactionDepth -= 1
                try? execute("ROLLBACK TO SAVEPOINT \(name);")
                try? execute("RELEASE SAVEPOINT \(name);")
                throw error
            }
        }
        try execute("BEGIN IMMEDIATE;")
        transactionDepth = 1
        do {
            let result = try body()
            transactionDepth = 0
            try execute("COMMIT;")
            return result
        } catch {
            transactionDepth = 0
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Schema version

    /// `PRAGMA user_version` — the migration authority (docs/15 §15.8).
    public func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { statement.reset() }
        if try statement.step() { return Int(statement.int(0)) }
        return 0
    }

    /// PRAGMA statements do not accept bound parameters; the value is an Int, so
    /// interpolation here can carry no text and no user input.
    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version=\(version);")
    }

    // MARK: - Small conveniences

    /// Run a parameterized statement to completion; returns `changes`.
    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql)
        try statement.bindAll(parameters)
        while try statement.step() {}
        statement.reset()
        return changes
    }

    /// First column of the first row, as Int64 (nil when there is no row / SQL NULL).
    public func scalarInt(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64? {
        let statement = try prepare(sql)
        try statement.bindAll(parameters)
        defer { statement.reset() }
        if try statement.step() {
            return statement.isNull(0) ? nil : statement.int(0)
        }
        return nil
    }

    /// First column of the first row, as String.
    public func scalarText(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> String? {
        let statement = try prepare(sql)
        try statement.bindAll(parameters)
        defer { statement.reset() }
        if try statement.step() { return statement.string(0) }
        return nil
    }

    /// Escape a Swift string as a single-quoted SQL string literal. Needed only where
    /// SQLite's grammar refuses bound parameters (ATTACH, VACUUM INTO); everything
    /// else uses `?` placeholders.
    public static func quoteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

// MARK: - Statement

public final class SQLiteStatement {

    private let owner: SQLiteDatabase
    private var stmt: OpaquePointer?

    public let sql: String

    fileprivate init(owner: SQLiteDatabase, stmt: OpaquePointer, sql: String) {
        self.owner = owner
        self.stmt = stmt
        self.sql = sql
    }

    deinit {
        if let raw = stmt {
            sqlite3_finalize(raw)
            stmt = nil
        }
    }

    /// Finalize now rather than at deinit. Idempotent.
    public func finalizeStatement() {
        if let raw = stmt {
            sqlite3_finalize(raw)
            stmt = nil
        }
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let raw = stmt else { throw SQLiteError.closed("statement is finalized") }
        return raw
    }

    public var parameterCount: Int {
        guard let raw = stmt else { return 0 }
        return Int(sqlite3_bind_parameter_count(raw))
    }

    public var columnCount: Int {
        guard let raw = stmt else { return 0 }
        return Int(sqlite3_column_count(raw))
    }

    public func columnName(_ column: Int) -> String {
        guard let raw = stmt, let name = sqlite3_column_name(raw, Int32(column)) else { return "" }
        return String(cString: name)
    }

    // MARK: Binding (1-based, as sqlite3 counts them)

    private func check(_ rc: Int32, _ index: Int) throws {
        if rc != SQLITE_OK {
            throw SQLiteError.bind(code: rc, message: owner.currentErrorMessage(), index: index)
        }
    }

    public func bind(_ index: Int, _ value: Int64) throws {
        let raw = try requireHandle()
        try check(sqlite3_bind_int64(raw, Int32(index), value), index)
    }

    public func bind(_ index: Int, _ value: Int) throws {
        try bind(index, Int64(value))
    }

    public func bind(_ index: Int, _ value: Bool) throws {
        try bind(index, Int64(value ? 1 : 0))
    }

    public func bind(_ index: Int, _ value: Double) throws {
        let raw = try requireHandle()
        try check(sqlite3_bind_double(raw, Int32(index), value), index)
    }

    /// SQLITE_TRANSIENT: sqlite3 copies the bytes during the call, so the temporary
    /// C buffer Swift materializes for `value` never outlives its own lifetime.
    public func bind(_ index: Int, _ value: String) throws {
        let raw = try requireHandle()
        try check(sqlite3_bind_text(raw, Int32(index), value, -1, sqliteTransient), index)
    }

    public func bind(_ index: Int, _ value: Data) throws {
        let raw = try requireHandle()
        let bytes: [UInt8] = Array(value)
        if bytes.isEmpty {
            try check(sqlite3_bind_zeroblob(raw, Int32(index), 0), index)
            return
        }
        let rc: Int32 = bytes.withUnsafeBytes { buffer in
            sqlite3_bind_blob(raw, Int32(index), buffer.baseAddress,
                              Int32(bytes.count), sqliteTransient)
        }
        try check(rc, index)
    }

    public func bindNull(_ index: Int) throws {
        let raw = try requireHandle()
        try check(sqlite3_bind_null(raw, Int32(index)), index)
    }

    public func bind(_ index: Int, _ value: Int64?) throws {
        if let v = value { try bind(index, v) } else { try bindNull(index) }
    }

    public func bind(_ index: Int, _ value: Int?) throws {
        if let v = value { try bind(index, Int64(v)) } else { try bindNull(index) }
    }

    public func bind(_ index: Int, _ value: Double?) throws {
        if let v = value { try bind(index, v) } else { try bindNull(index) }
    }

    public func bind(_ index: Int, _ value: String?) throws {
        if let v = value { try bind(index, v) } else { try bindNull(index) }
    }

    public func bind(_ index: Int, _ value: Data?) throws {
        if let v = value { try bind(index, v) } else { try bindNull(index) }
    }

    public func bind(_ index: Int, _ value: SQLiteValue) throws {
        switch value {
        case .null: try bindNull(index)
        case .integer(let v): try bind(index, v)
        case .real(let v): try bind(index, v)
        case .text(let v): try bind(index, v)
        case .blob(let v): try bind(index, v)
        }
    }

    /// Bind a whole parameter list positionally, 1-based.
    public func bindAll(_ values: [SQLiteValue]) throws {
        var index = 1
        for value in values {
            try bind(index, value)
            index += 1
        }
    }

    // MARK: Stepping

    /// True = a row is available; false = the statement finished.
    public func step() throws -> Bool {
        let raw = try requireHandle()
        let rc = sqlite3_step(raw)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw SQLiteError.step(code: rc, message: owner.currentErrorMessage(), sql: sql)
    }

    /// Step to completion, discarding rows.
    public func run() throws {
        while try step() {}
    }

    public func reset() {
        guard let raw = stmt else { return }
        _ = sqlite3_reset(raw)
        _ = sqlite3_clear_bindings(raw)
    }

    // MARK: Reading (0-based, as sqlite3 counts them)

    public func isNull(_ column: Int) -> Bool {
        guard let raw = stmt else { return true }
        return sqlite3_column_type(raw, Int32(column)) == SQLITE_NULL
    }

    public func int(_ column: Int) -> Int64 {
        guard let raw = stmt else { return 0 }
        return sqlite3_column_int64(raw, Int32(column))
    }

    public func double(_ column: Int) -> Double {
        guard let raw = stmt else { return 0 }
        return sqlite3_column_double(raw, Int32(column))
    }

    public func string(_ column: Int) -> String? {
        guard let raw = stmt else { return nil }
        if sqlite3_column_type(raw, Int32(column)) == SQLITE_NULL { return nil }
        guard let text = sqlite3_column_text(raw, Int32(column)) else { return nil }
        let length = Int(sqlite3_column_bytes(raw, Int32(column)))
        if length <= 0 { return "" }
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF8.self)
    }

    public func data(_ column: Int) -> Data? {
        guard let raw = stmt else { return nil }
        if sqlite3_column_type(raw, Int32(column)) == SQLITE_NULL { return nil }
        let length = Int(sqlite3_column_bytes(raw, Int32(column)))
        if length <= 0 { return Data() }
        guard let bytes = sqlite3_column_blob(raw, Int32(column)) else { return Data() }
        return Data(bytes: bytes, count: length)
    }

    // Optional-flavoured readers, so callers do not repeat the isNull dance.

    public func optionalInt(_ column: Int) -> Int64? {
        isNull(column) ? nil : int(column)
    }

    public func optionalIntValue(_ column: Int) -> Int? {
        isNull(column) ? nil : Int(int(column))
    }

    public func optionalDouble(_ column: Int) -> Double? {
        isNull(column) ? nil : double(column)
    }

    public func bool(_ column: Int) -> Bool {
        int(column) != 0
    }
}

#else

// Linux (and anywhere else without the SQLite3 module): the catalog cannot exist.
// The types stay declared so callers compile; every entry point refuses honestly
// rather than silently pretending to persist anything.

import Foundation

public enum SQLiteError: Error, CustomStringConvertible {
    case unavailable

    /// Never: "the module is missing" is not "the file is damaged".
    public var indicatesCorruptDatabase: Bool { false }

    public var description: String { "sqlite3: unavailable on this platform" }
}

public enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public static func int(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
    public static func bool(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }

    public static func optionalInteger(_ value: Int64?) -> SQLiteValue {
        if let v = value { return .integer(v) }
        return .null
    }

    public static func optionalInt(_ value: Int?) -> SQLiteValue {
        if let v = value { return .integer(Int64(v)) }
        return .null
    }

    public static func optionalReal(_ value: Double?) -> SQLiteValue {
        if let v = value { return .real(v) }
        return .null
    }

    public static func optionalText(_ value: String?) -> SQLiteValue {
        if let v = value { return .text(v) }
        return .null
    }

    public static func optionalBlob(_ value: Data?) -> SQLiteValue {
        if let v = value { return .blob(v) }
        return .null
    }
}

public final class SQLiteStatement {
    public let sql: String = ""

    private init() {}
}

public final class SQLiteDatabase {
    public let path: String

    public init(path: String) throws {
        self.path = path
        throw SQLiteError.unavailable
    }

    public func close() {}

    public var isOpen: Bool { false }

    public var lastInsertRowID: Int64 { 0 }

    public var changes: Int { 0 }

    public func execute(_ sql: String) throws { throw SQLiteError.unavailable }

    public func prepare(_ sql: String) throws -> SQLiteStatement { throw SQLiteError.unavailable }

    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T { throw SQLiteError.unavailable }

    public func userVersion() throws -> Int { throw SQLiteError.unavailable }

    public func setUserVersion(_ version: Int) throws { throw SQLiteError.unavailable }

    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        throw SQLiteError.unavailable
    }

    public func scalarInt(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64? {
        throw SQLiteError.unavailable
    }

    public func scalarText(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> String? {
        throw SQLiteError.unavailable
    }

    public static func quoteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

#endif
