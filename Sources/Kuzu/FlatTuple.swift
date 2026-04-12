//
//  kuzu-swift
//  https://github.com/kuzudb/kuzu-swift
//
//  Copyright © 2023 - 2025 Kùzu Inc.
//  This code is licensed under MIT license (see LICENSE for details)

@_implementationOnly import cxx_kuzu

/// A class representing a row in the result set of a query.
/// FlatTuple provides access to the values in a query result row and methods to convert them to different formats.
/// It conforms to `CustomStringConvertible` protocol for easy string representation.
public final class FlatTuple: CustomStringConvertible, @unchecked Sendable {
    internal var cFlatTuple: kuzu_flat_tuple
    // Strong reference intentional: keeps QueryResult alive while FlatTuple is in use
    internal var queryResult: QueryResult

    internal init(
        _ queryResult: QueryResult,
        _ cFlatTuple: kuzu_flat_tuple
    ) {
        self.cFlatTuple = cFlatTuple
        self.queryResult = queryResult
    }

    deinit {
        kuzu_flat_tuple_destroy(&cFlatTuple)
    }

    /// Returns the string representation of the FlatTuple.
    /// The string representation contains the values of the tuple separated by vertical bars.
    public var description: String {
        let cString: UnsafeMutablePointer<CChar> = kuzu_flat_tuple_to_string(
            &cFlatTuple
        )
        defer { kuzu_destroy_string(cString) }
        return String(cString: cString)
    }

    /// Returns the value at the given index in the FlatTuple.
    /// - Parameter index: The index of the value to retrieve.
    /// - Returns: The value at the specified index, or nil if the value is null.
    /// - Throws: `KuzuError.getValueFailed` if retrieving the value fails.
    public func getValue(_ index: UInt64) throws -> Any? {
        var cValue = kuzu_value()
        let state = kuzu_flat_tuple_get_value(&cFlatTuple, index, &cValue)
        if state != KuzuSuccess {
            throw KuzuError.getValueFailed(
                "Get value failed with error code: \(state)"
            )
        }
        defer { kuzu_value_destroy(&cValue) }
        return try kuzuValueToSwift(&cValue)
    }

    /// Returns the values of the FlatTuple as a dictionary.
    /// The keys of the dictionary are the column names in the query result.
    /// - Returns: A dictionary mapping column names to their corresponding values.
    /// - Throws: `KuzuError.getValueFailed` if retrieving any value fails.
    public func getAsDictionary() throws -> [String: Any?] {
        var result: [String: Any] = [:]
        let keys = queryResult.getColumnNames()
        for i in 0..<keys.count {
            let key = keys[i]
            let value = try getValue(UInt64(i))
            result[key] = value
        }
        return result
    }

    /// Returns the values of the FlatTuple as an array.
    /// The order of the values in the array is the same as the order of the columns in the query result.
    /// - Returns: An array containing all values in the tuple.
    /// - Throws: `KuzuError.getValueFailed` if retrieving any value fails.
    public func getAsArray() throws -> [Any?] {
        var result: [Any?] = []
        let count = queryResult.getColumnCount()
        for i in UInt64(0)..<count {
            let value = try getValue(i)
            result.append(value)
        }
        return result
    }

    // MARK: - Typed Column Access

    /// Type-safe value access with auto-conversion.
    /// - Parameter index: Column index (0-based)
    /// - Returns: Value cast to the requested type
    /// - Throws: `KuzuError.getValueFailed` if type conversion fails or value is null
    public func get<T>(_ index: UInt64) throws -> T {
        guard let value = try getValue(index) else {
            throw KuzuError.getValueFailed("Column \(index) is NULL")
        }
        if let result = value as? T {
            return result
        }
        if let converted: T = Self.autoConvert(value) {
            return converted
        }
        throw KuzuError.getValueFailed(
            "Cannot convert column \(index) value of type \(type(of: value)) to \(T.self)"
        )
    }

    /// Type-safe value access with explicit type parameter.
    /// - Parameters:
    ///   - index: Column index (0-based)
    ///   - type: The target type to convert to
    /// - Returns: Value cast to the requested type
    /// - Throws: `KuzuError.getValueFailed` if type conversion fails or value is null
    public func get<T>(_ index: UInt64, as type: T.Type) throws -> T {
        return try get(index)
    }

    /// Nil-safe value access for nullable columns.
    /// - Parameter index: Column index (0-based)
    /// - Returns: Value cast to the requested type, or nil if the value is null or conversion fails
    public func getOptional<T>(_ index: UInt64) -> T? {
        guard let value = try? getValue(index) else { return nil }
        if let result = value as? T { return result }
        return Self.autoConvert(value)
    }

    /// Type-safe value access by column name.
    /// - Parameter columnName: The column name (e.g. "n.name")
    /// - Returns: Value cast to the requested type
    /// - Throws: `KuzuError.getValueFailed` if column not found, type conversion fails, or value is null
    public func get<T>(_ columnName: String) throws -> T {
        let names = queryResult.getColumnNames()
        guard let index = names.firstIndex(of: columnName) else {
            throw KuzuError.getValueFailed("Column '\(columnName)' not found")
        }
        return try get(UInt64(index))
    }

    /// Nil-safe value access by column name.
    /// - Parameter columnName: The column name (e.g. "n.name")
    /// - Returns: Value cast to the requested type, or nil if column not found, value is null, or conversion fails
    public func getOptional<T>(_ columnName: String) -> T? {
        let names = queryResult.getColumnNames()
        guard let index = names.firstIndex(of: columnName) else { return nil }
        return getOptional(UInt64(index))
    }

    /// Auto-converts common numeric types.
    private static func autoConvert<T>(_ value: Any) -> T? {
        if T.self == Int.self {
            if let v = value as? Int64 { return Int(v) as? T }
            if let v = value as? Int32 { return Int(v) as? T }
            if let v = value as? Int16 { return Int(v) as? T }
            if let v = value as? Int8 { return Int(v) as? T }
            if let v = value as? UInt64 { return Int(v) as? T }
        }
        if T.self == Double.self {
            if let v = value as? Float { return Double(v) as? T }
        }
        if T.self == Float.self {
            if let v = value as? Double { return Float(v) as? T }
        }
        if T.self == String.self {
            return "\(value)" as? T
        }
        return nil
    }
}
