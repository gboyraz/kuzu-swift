//
//  kuzu-swift
//  https://github.com/kuzudb/kuzu-swift
//
//  Copyright © 2023 - 2025 Kùzu Inc.
//  This code is licensed under MIT license (see LICENSE for details)

@_implementationOnly import cxx_kuzu

/// Represents a connection to a Kuzu database.
///
/// Connection is thread-safe. Multiple threads can call ``query(_:)`` and ``execute(_:_:)`` concurrently.
/// Queries are serialized internally via C++ mutex — for true parallelism, use separate Connections.
public final class Connection: @unchecked Sendable {
    internal var cConnection: kuzu_connection
    internal var database: Database

    /// Opens a connection to the specified database.
    /// - Parameter database: The database to connect to
    /// - Throws: KuzuError if connection initialization fails
    public init(_ database: Database) throws {
        cConnection = kuzu_connection()
        let state = kuzu_connection_init(&database.cDatabase, &self.cConnection)
        if state != KuzuSuccess {
            throw KuzuError.connectionInitializationFailed(
                "Connection initialization failed with error code: \(state)"
            )
        }
        self.database = database
    }

    deinit {
        kuzu_connection_destroy(&cConnection)
    }

    /// Executes a query string and returns the result.
    /// - Parameter cypher: The Cypher query string to execute
    /// - Returns: A QueryResult containing the results of the query
    /// - Throws: KuzuError if query execution fails
    public func query(_ cypher: String) throws -> QueryResult {
        var cQueryResult = kuzu_query_result()
        kuzu_connection_query(&cConnection, cypher, &cQueryResult)
        if !kuzu_query_result_is_success(&cQueryResult) {
            let cErrorMesage: UnsafeMutablePointer<CChar>? =
                kuzu_query_result_get_error_message(&cQueryResult)
            defer {
                kuzu_query_result_destroy(&cQueryResult)
                kuzu_destroy_string(cErrorMesage)
            }
            if cErrorMesage == nil {
                throw KuzuError.queryExecutionFailed(
                    "Query execution failed with an unknown error."
                )
            } else {
                let errorMessage = String(cString: cErrorMesage!)
                throw KuzuError.queryExecutionFailed(errorMessage)
            }
        }
        return QueryResult(self, cQueryResult)
    }

    /// Returns a prepared statement for the specified query string.
    /// The prepared statement can be used to execute the query with parameters.
    /// - Parameter cypher: The Cypher query string to prepare
    /// - Returns: A PreparedStatement that can be used to execute the query with parameters
    /// - Throws: KuzuError if statement preparation fails
    public func prepare(_ cypher: String) throws -> PreparedStatement {
        var cPreparedStatement = kuzu_prepared_statement()
        kuzu_connection_prepare(&cConnection, cypher, &cPreparedStatement)
        if !kuzu_prepared_statement_is_success(&cPreparedStatement) {
            let cErrorMesage: UnsafeMutablePointer<CChar>? =
                kuzu_prepared_statement_get_error_message(&cPreparedStatement)
            defer {
                kuzu_destroy_string(cErrorMesage)
                kuzu_prepared_statement_destroy(&cPreparedStatement)
            }
            if cErrorMesage == nil {
                throw KuzuError.prepareStatementFailed(
                    "Prepare statement failed with an unknown error."
                )
            } else {
                let errorMessage = String(cString: cErrorMesage!)
                throw KuzuError.prepareStatementFailed(errorMessage)
            }
        }
        let preparedStatement = PreparedStatement(self, cPreparedStatement)
        return preparedStatement
    }

    /// Executes the specified prepared statement with the given parameters and returns the result.
    /// - Parameters:
    ///   - preparedStatement: The prepared statement to execute
    ///   - parameters: A dictionary mapping parameter names to their values
    /// - Returns: A QueryResult containing the results of the query
    /// - Throws: KuzuError if query execution fails
    public func execute<T>(
        _ preparedStatement: PreparedStatement,
        _ parameters: [String: T?]
    ) throws -> QueryResult {

        var cQueryResult = kuzu_query_result()
        for (key, value) in parameters {
            let cValue = try swiftValueToKuzuValue(value)
            defer {
                kuzu_value_destroy(cValue)
            }
            let state = kuzu_prepared_statement_bind_value(
                &preparedStatement.cPreparedStatement,
                key,
                cValue
            )
            if state != KuzuSuccess {
                throw KuzuError.queryExecutionFailed(
                    "Failed to bind value with status \(state)"
                )
            }
        }
        kuzu_connection_execute(
            &cConnection,
            &preparedStatement.cPreparedStatement,
            &cQueryResult
        )
        if !kuzu_query_result_is_success(&cQueryResult) {
            let cErrorMesage: UnsafeMutablePointer<CChar>? =
                kuzu_query_result_get_error_message(&cQueryResult)
            defer {
                kuzu_query_result_destroy(&cQueryResult)
                kuzu_destroy_string(cErrorMesage)
            }
            if cErrorMesage == nil {
                throw KuzuError.queryExecutionFailed(
                    "Query execution failed with an unknown error."
                )
            } else {
                let errorMessage = String(cString: cErrorMesage!)
                throw KuzuError.queryExecutionFailed(errorMessage)
            }
        }
        return QueryResult(self, cQueryResult)
    }

    /// Sets the maximum number of threads that can be used for executing a query in parallel.
    /// - Parameter numThreads: The maximum number of threads to use
    public func setMaxNumThreadForExec(_ numThreads: UInt64) {
        kuzu_connection_set_max_num_thread_for_exec(&cConnection, numThreads)
    }

    /// Returns the maximum number of threads that can be used for executing a query in parallel.
    /// - Returns: The maximum number of threads
    public func getMaxNumThreadForExec() -> UInt64 {
        var numThreads = UInt64()
        kuzu_connection_get_max_num_thread_for_exec(&cConnection, &numThreads)
        return numThreads
    }

    /// Sets the timeout for the queries executed on the connection.
    /// The timeout is specified in milliseconds. A value of 0 means no timeout.
    /// If a query takes longer than the specified timeout, it will be interrupted.
    /// - Parameter milliseconds: The timeout duration in milliseconds
    public func setQueryTimeout(_ milliseconds: UInt64) {
        kuzu_connection_set_query_timeout(&cConnection, milliseconds)
    }

    /// Interrupts the execution of the current query on the connection.
    public func interrupt() {
        kuzu_connection_interrupt(&cConnection)
    }

    // MARK: - Secondary Hash Index

    /// Creates a secondary hash index on a node table property for O(1) lookups.
    /// - Parameters:
    ///   - table: The name of the node table.
    ///   - property: The name of the property to index.
    /// - Throws: KuzuError if index creation fails.
    public func createHashIndex(table: String, property: String) throws {
        let result = try query("CALL CREATE_HASH_INDEX('\(table)', '\(property)')")
        result.close()
    }

    /// Looks up node internal IDs by an indexed property value (String).
    /// - Parameters:
    ///   - table: The name of the node table.
    ///   - property: The name of the indexed property.
    ///   - value: The string value to look up.
    /// - Returns: An array of matching internal IDs.
    /// - Throws: KuzuError if the lookup fails.
    public func lookupByIndex(table: String, property: String, value: String) throws -> [KuzuInternalId] {
        let result = try query("CALL QUERY_HASH_INDEX('\(table)', '\(property)', '\(value)') RETURN node_id")
        defer { result.close() }
        var ids: [KuzuInternalId] = []
        while result.hasNext() {
            if let tuple = try result.getNext() {
                let val = try tuple.getValue(0)
                if let id = val as? KuzuInternalId {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    /// Looks up node internal IDs by an indexed property value (Int64).
    /// - Parameters:
    ///   - table: The name of the node table.
    ///   - property: The name of the indexed property.
    ///   - value: The integer value to look up.
    /// - Returns: An array of matching internal IDs.
    /// - Throws: KuzuError if the lookup fails.
    public func lookupByIndex(table: String, property: String, value: Int64) throws -> [KuzuInternalId] {
        let result = try query("CALL QUERY_HASH_INDEX('\(table)', '\(property)', '\(value)') RETURN node_id")
        defer { result.close() }
        var ids: [KuzuInternalId] = []
        while result.hasNext() {
            if let tuple = try result.getNext() {
                let val = try tuple.getValue(0)
                if let id = val as? KuzuInternalId {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    /// Drops a secondary hash index on a node table property.
    /// - Parameters:
    ///   - table: The name of the node table.
    ///   - property: The name of the indexed property.
    /// - Throws: KuzuError if dropping the index fails.
    public func dropHashIndex(table: String, property: String) throws {
        let result = try query("CALL DROP_HASH_INDEX('\(table)', '\(property)')")
        result.close()
    }

    /// Creates a secondary hash index if one doesn't already exist.
    /// Safe to call on every app launch — idempotent.
    /// - Parameters:
    ///   - table: The name of the node table.
    ///   - property: The name of the property to index.
    /// - Returns: `true` if the index was created, `false` if it already existed.
    /// - Throws: KuzuError if index creation fails for reasons other than the index already existing.
    @discardableResult
    public func createHashIndexIfNotExists(table: String, property: String) throws -> Bool {
        do {
            try createHashIndex(table: table, property: property)
            return true
        } catch {
            let msg = "\(error)"
            if msg.contains("already exists") {
                return false
            }
            throw error
        }
    }

    /// Checks whether a hash index exists on the given table property.
    /// - Parameters:
    ///   - table: The name of the node table.
    ///   - property: The name of the property to check.
    /// - Returns: `true` if a hash index exists on the property, `false` otherwise.
    /// - Throws: KuzuError if the check fails.
    public func hasHashIndex(table: String, property: String) throws -> Bool {
        let indexes = try listHashIndexes(table: table)
        return indexes.contains(property)
    }

    /// Lists all hash indexes on a table. Returns property names that have indexes.
    /// - Parameter table: The name of the node table.
    /// - Returns: An array of property names that have hash indexes.
    /// - Throws: KuzuError if the query fails.
    public func listHashIndexes(table: String) throws -> [String] {
        let result = try query("CALL LIST_HASH_INDEXES('\(table)') RETURN property_name")
        defer { result.close() }
        var names: [String] = []
        while result.hasNext() {
            if let tuple = try result.getNext() {
                let val = try tuple.getValue(0)
                if let name = val as? String {
                    names.append(name)
                }
            }
        }
        return names
    }

    // MARK: - Composite Hash Index

    /// Creates a composite hash index on multiple properties.
    /// - Parameters:
    ///   - table: The name of the node table.
    ///   - properties: The names of the properties to include in the composite index.
    /// - Throws: KuzuError if index creation fails.
    public func createCompositeIndex(table: String, properties: [String]) throws {
        let propStr = properties.joined(separator: ",")
        let result = try query("CALL CREATE_HASH_INDEX('\(table)', '\(propStr)')")
        result.close()
    }

    /// Creates a composite hash index if one doesn't already exist.
    /// Safe to call on every app launch — idempotent.
    /// - Parameters:
    ///   - table: The name of the node table.
    ///   - properties: The names of the properties to include in the composite index.
    /// - Returns: `true` if the index was created, `false` if it already existed.
    /// - Throws: KuzuError if index creation fails for reasons other than the index already existing.
    @discardableResult
    public func createCompositeIndexIfNotExists(table: String, properties: [String]) throws -> Bool {
        do {
            try createCompositeIndex(table: table, properties: properties)
            return true
        } catch {
            let msg = "\(error)"
            if msg.contains("already exists") {
                return false
            }
            throw error
        }
    }

    /// Looks up node internal IDs by composite indexed property values.
    /// - Parameters:
    ///   - table: The name of the node table.
    ///   - properties: The names of the indexed properties (in order).
    ///   - values: The string values to look up (in order matching properties).
    /// - Returns: An array of matching internal IDs.
    /// - Throws: KuzuError if the lookup fails.
    public func lookupByCompositeIndex(table: String, properties: [String], values: [String]) throws -> [KuzuInternalId] {
        let propStr = properties.joined(separator: ",")
        let valStr = values.joined(separator: ",")
        let result = try query("CALL QUERY_HASH_INDEX('\(table)', '\(propStr)', '\(valStr)') RETURN node_id")
        defer { result.close() }
        var ids: [KuzuInternalId] = []
        while result.hasNext() {
            if let tuple = try result.getNext() {
                let val = try tuple.getValue(0)
                if let id = val as? KuzuInternalId {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    // MARK: - HNSW Vector Index

    /// Creates an HNSW vector index on an embedding column.
    /// - Parameters:
    ///   - table: Node table name (e.g., "Image").
    ///   - indexName: Name for the index (e.g., "emb_idx").
    ///   - property: Embedding column name (e.g., "embedding").
    ///   - metric: Distance metric — "cosine", "l2", or "dotproduct" (default: "cosine").
    /// - Throws: KuzuError if index creation fails.
    public func createVectorIndex(
        table: String,
        indexName: String,
        property: String,
        metric: String = "cosine"
    ) throws {
        let result = try query(
            "CALL CREATE_VECTOR_INDEX('\(table)', '\(indexName)', '\(property)', metric := '\(metric)')"
        )
        result.close()
    }

    /// Creates a vector index if one doesn't already exist. Safe to call on every app launch.
    /// - Parameters:
    ///   - table: Node table name.
    ///   - indexName: Name for the index.
    ///   - property: Embedding column name.
    ///   - metric: Distance metric — "cosine", "l2", or "dotproduct" (default: "cosine").
    /// - Returns: `true` if the index was created, `false` if it already existed.
    /// - Throws: KuzuError if index creation fails for reasons other than the index already existing.
    @discardableResult
    public func createVectorIndexIfNotExists(
        table: String,
        indexName: String,
        property: String,
        metric: String = "cosine"
    ) throws -> Bool {
        do {
            try createVectorIndex(table: table, indexName: indexName, property: property, metric: metric)
            return true
        } catch {
            let msg = "\(error)"
            if msg.contains("already exists") {
                return false
            }
            throw error
        }
    }

    /// Searches for K nearest neighbors using an HNSW vector index.
    /// - Parameters:
    ///   - table: Node table name.
    ///   - indexName: Index name.
    ///   - queryVector: The query embedding as a `[Float]` array.
    ///   - k: Number of nearest neighbors to return.
    ///   - filter: Optional Cypher filter (e.g., `"WHERE nn.collection_id = 5"`).
    /// - Returns: Array of ``VectorSearchResult`` sorted by distance ascending.
    /// - Throws: KuzuError if the query fails.
    public func searchNearest(
        table: String,
        indexName: String,
        queryVector: [Float],
        k: Int,
        filter: String? = nil
    ) throws -> [VectorSearchResult] {
        let vectorStr = "[" + queryVector.map { String($0) }.joined(separator: ",") + "]"

        var cypher: String
        if let filter = filter {
            cypher = "CALL QUERY_VECTOR_INDEX('\(table)', '\(indexName)', CAST(\(vectorStr) AS FLOAT[\(queryVector.count)]), \(k), filter_statement := '\(filter)') YIELD node, distance RETURN node, distance ORDER BY distance ASC"
        } else {
            cypher = "CALL QUERY_VECTOR_INDEX('\(table)', '\(indexName)', CAST(\(vectorStr) AS FLOAT[\(queryVector.count)]), \(k)) YIELD node, distance RETURN node, distance ORDER BY distance ASC"
        }

        let result = try query(cypher)
        defer { result.close() }

        var results: [VectorSearchResult] = []
        while result.hasNext() {
            if let tuple = try result.getNext() {
                // QUERY_VECTOR_INDEX yields node as a NODE and distance as DOUBLE
                let distance = try tuple.getValue(1) as? Double ?? 0.0
                if let node = try tuple.getValue(0) as? KuzuNode {
                    results.append(VectorSearchResult(nodeID: node.id, distance: distance))
                } else if let nodeID = try tuple.getValue(0) as? KuzuInternalId {
                    results.append(VectorSearchResult(nodeID: nodeID, distance: distance))
                }
            }
        }
        return results
    }

    /// Drops an HNSW vector index.
    /// - Parameters:
    ///   - table: Node table name.
    ///   - indexName: Index name.
    /// - Throws: KuzuError if dropping the index fails.
    public func dropVectorIndex(table: String, indexName: String) throws {
        let result = try query("CALL DROP_VECTOR_INDEX('\(table)', '\(indexName)')")
        result.close()
    }
}

/// Search result from a vector index KNN query.
public struct VectorSearchResult {
    /// The internal ID of the matched node.
    public let nodeID: KuzuInternalId
    /// The distance from the query vector (lower is closer).
    public let distance: Double
}
