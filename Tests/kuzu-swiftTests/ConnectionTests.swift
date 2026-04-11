//
//  kuzu-swift
//  https://github.com/kuzudb/kuzu-swift
//
//  Copyright © 2023 - 2025 Kùzu Inc.
//  This code is licensed under MIT license (see LICENSE for details)

import Foundation
import XCTest

@testable import Kuzu

final class ConnectionTests: XCTestCase {
    var db: Database!
    var path: String!

    override func setUp() {
        super.setUp()
        (db, _, path) = try! getTestDatabase()
    }

    override func tearDown() {
        deleteTestDatabaseDirectory(path)
        super.tearDown()
    }

    func testOpenConnection() throws {
        _ = try Connection(db)
    }

    func testGetMaxNumThreads() throws {
        let conn = try Connection(db)
        XCTAssertEqual(conn.getMaxNumThreadForExec(), 4)  // Default value
    }

    func testSetMaxNumThreads() throws {
        let conn = try Connection(db)
        conn.setMaxNumThreadForExec(3)
        XCTAssertEqual(conn.getMaxNumThreadForExec(), 3)
    }

    // TODO: fix this test on other platforms
    #if os(macOS)
        func testInterrupt() async throws {
            let conn = try Connection(db)
            let largeQuery =
                "UNWIND RANGE(1,100000) AS x UNWIND RANGE(1, 100000) AS y RETURN COUNT(x + y);"

            // Launch the query on a Task
            let task = Task { @Sendable in
                do {
                    _ = try conn.query(largeQuery)
                    XCTFail("Expected query to be interrupted")
                } catch let error as KuzuError {
                    XCTAssertEqual(error.message, "Interrupted.")
                } catch {
                    XCTFail("Query failed, but not due to interruption")
                }
            }

            // Give the query time to start
            try await Task.sleep(nanoseconds: 1000_000_000)
            conn.interrupt()

            // Wait for task to finish
            await task.value
        }
    #endif

    func testSetTimeout() throws {
        let conn = try Connection(db)
        conn.setQueryTimeout(100)

        do {
            _ = try conn.query(
                "UNWIND RANGE(1,100000) AS x UNWIND RANGE(1, 100000) AS y RETURN COUNT(x + y);"
            )
            XCTFail("Expected timeout error")
        } catch let error as KuzuError {
            XCTAssertEqual(error.message, "Interrupted.")
        } catch {
            XCTFail("Query failed, but not due to interruption")
        }
    }

    func testQuery() throws {
        let conn = try Connection(db)
        let result = try conn.query("RETURN CAST(1, \"INT64\");")
        XCTAssertTrue(result.hasNext())

        let tuple = try result.getNext()!
        let values = try tuple.getAsArray()
        XCTAssertEqual(values[0] as! Int64, 1)
    }

    func testQueryError() throws {
        let conn = try Connection(db)
        do {
            _ = try conn.query("RETURN a;")
            XCTFail("Expected error")
        } catch let error as KuzuError {
            XCTAssertTrue(error.message.contains("Variable a is not in scope."))
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testPrepare() throws {
        let conn = try Connection(db)
        _ = try conn.prepare("RETURN $a;")
    }

    func testPrepareError() throws {
        let conn = try Connection(db)
        do {
            _ = try conn.prepare("MATCH RETURN $a;")
            XCTFail("Expected error")
        } catch let error as KuzuError {
            XCTAssertTrue(error.message.contains("Parser exception"))
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testExecute() throws {
        let conn = try Connection(db)
        let stmt = try conn.prepare("RETURN $a;")
        #if os(Linux)
            let result = try conn.execute(
                stmt,
                ["a": KuzuInt64Wrapper(value: 1)]
            )
        #else
            let result = try conn.execute(stmt, ["a": Int64(1)])
        #endif

        XCTAssertTrue(result.hasNext())
        let tuple = try result.getNext()!
        let values = try tuple.getAsArray()
        XCTAssertEqual(values[0] as! Int64, 1)
    }

    func testExecuteError() throws {
        let conn = try Connection(db)
        let stmt = try conn.prepare("RETURN $a;")

        do {
            #if os(Linux)
                _ = try conn.execute(stmt, ["b": KuzuInt64Wrapper(value: 1)])
            #else
                _ = try conn.execute(stmt, ["b": Int64(1)])
            #endif
            XCTFail("Expected error")
        } catch let error as KuzuError {
            XCTAssertTrue(error.message.contains("Parameter b not found"))
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    /// Regression test for GitHub issue #25: PreparedStatement reuse causes double-free.
    /// When a PreparedStatement is executed multiple times, the resulting QueryResult
    /// objects must not share internal C++ memory. Previously, ARC-deferred deallocation
    /// of old QueryResult objects would free memory that a new execution had already
    /// invalidated, causing a malloc double-free crash.
    func testPreparedStatementReuseNoDoubleFree() throws {
        let conn = try Connection(db)

        // Create a table to delete from
        _ = try conn.query(
            "CREATE NODE TABLE TestItem (id STRING, PRIMARY KEY (id));"
        )
        _ = try conn.query("CREATE (t:TestItem {id: 'item1'});")
        _ = try conn.query("CREATE (t:TestItem {id: 'item2'});")
        _ = try conn.query("CREATE (t:TestItem {id: 'item3'});")

        // Prepare once, execute multiple times — this previously crashed
        let stmt = try conn.prepare(
            "MATCH (t:TestItem {id: $id}) DELETE t"
        )

        for itemId in ["item1", "item2", "item3"] {
            NSLog("Executing DELETE for %@", itemId)
            _ = try conn.execute(stmt, ["id": itemId] as [String: Any?])
        }

        // Verify all items were deleted
        let result = try conn.query(
            "MATCH (t:TestItem) RETURN COUNT(t);"
        )
        XCTAssertTrue(result.hasNext())
        let tuple = try result.getNext()!
        let count = try tuple.getValue(0) as! Int64
        XCTAssertEqual(count, 0, "All TestItem nodes should be deleted")
        NSLog("testPreparedStatementReuseNoDoubleFree passed — no crash")
    }

    /// Regression test for GitHub issue #25 (second comment): interleaved PreparedStatements
    /// from the same Connection. Each QueryResult is independent and owns its data.
    func testInterleavedPreparedStatementsNoDoubleFree() throws {
        let conn = try Connection(db)

        // Set up: node tables with edges (mimics the moveToTrash pattern from issue #25)
        _ = try conn.query(
            "CREATE NODE TABLE Image (id STRING, PRIMARY KEY (id));"
        )
        _ = try conn.query(
            "CREATE NODE TABLE Collection (id STRING, PRIMARY KEY (id));"
        )
        _ = try conn.query(
            "CREATE REL TABLE BELONGS_TO (FROM Image TO Collection);"
        )

        // Create images and collections
        _ = try conn.query("CREATE (c:Collection {id: 'source'});")
        _ = try conn.query("CREATE (c:Collection {id: 'trash'});")
        for i in 1...5 {
            _ = try conn.query("CREATE (i:Image {id: 'img\(i)'});")
            _ = try conn.query(
                "MATCH (i:Image {id: 'img\(i)'}), (c:Collection {id: 'source'}) CREATE (i)-[:BELONGS_TO]->(c);"
            )
        }

        // This is the exact pattern from the issue: interleaved prepare+execute with
        // different statements in the same loop, producing multiple QueryResults.
        let removeStmt = try conn.prepare("""
            MATCH (i:Image {id: $iid})-[b:BELONGS_TO]->(c:Collection {id: $cid})
            DELETE b
            """)

        let checkStmt = try conn.prepare("""
            MATCH (i:Image {id: $iid})-[b:BELONGS_TO]->(c:Collection {id: $cid})
            RETURN count(b)
            """)

        let createStmt = try conn.prepare("""
            MATCH (i:Image {id: $iid}), (c:Collection {id: $cid})
            CREATE (i)-[:BELONGS_TO]->(c)
            """)

        for i in 1...5 {
            let imageId = "img\(i)"

            // 1. Delete edge from source
            _ = try conn.execute(
                removeStmt,
                ["iid": imageId, "cid": "source"] as [String: Any?]
            )

            // 2. Check if already in trash
            let checkResult = try conn.execute(
                checkStmt,
                ["iid": imageId, "cid": "trash"] as [String: Any?]
            )
            if checkResult.hasNext() {
                let tuple = try checkResult.getNext()!
                let count = try tuple.getValue(0) as! Int64
                XCTAssertEqual(count, 0)
            }

            // 3. Create edge to trash
            _ = try conn.execute(
                createStmt,
                ["iid": imageId, "cid": "trash"] as [String: Any?]
            )
        }

        // Verify: all images should now belong to trash, not source
        let result = try conn.query(
            "MATCH (i:Image)-[:BELONGS_TO]->(c:Collection {id: 'trash'}) RETURN COUNT(i);"
        )
        XCTAssertTrue(result.hasNext())
        let tuple = try result.getNext()!
        let count = try tuple.getValue(0) as! Int64
        XCTAssertEqual(count, 5, "All 5 images should be in trash")

        let sourceResult = try conn.query(
            "MATCH (i:Image)-[:BELONGS_TO]->(c:Collection {id: 'source'}) RETURN COUNT(i);"
        )
        XCTAssertTrue(sourceResult.hasNext())
        let sourceTuple = try sourceResult.getNext()!
        let sourceCount = try sourceTuple.getValue(0) as! Int64
        XCTAssertEqual(sourceCount, 0, "No images should remain in source")

        NSLog("testInterleavedPreparedStatementsNoDoubleFree passed — no crash")
    }

    /// Tests that concurrent query/execute calls on the same Connection do not crash.
    func testConcurrentConnectionAccess() throws {
        let conn = try Connection(db)

        // Set up a small table for mixed read/write queries
        _ = try conn.query(
            "CREATE NODE TABLE ConcItem (id INT64, val STRING, PRIMARY KEY (id));"
        )
        for i in 0..<10 {
            _ = try conn.query("CREATE (n:ConcItem {id: \(i), val: 'init'});")
        }

        let iterations = 50
        let workers = 4
        let expectation = XCTestExpectation(description: "All concurrent workers finish")
        expectation.expectedFulfillmentCount = workers

        let errors = NSLock()
        var collectedErrors: [Error] = []

        for workerIdx in 0..<workers {
            DispatchQueue.global().async {
                for i in 0..<iterations {
                    do {
                        if i % 2 == 0 {
                            // Read query
                            let result = try conn.query(
                                "MATCH (n:ConcItem) RETURN COUNT(n);"
                            )
                            _ = result.hasNext()
                        } else {
                            // Write query
                            _ = try conn.query(
                                "MATCH (n:ConcItem {id: \(workerIdx)}) SET n.val = 'w\(workerIdx)_i\(i)';"
                            )
                        }
                    } catch {
                        errors.lock()
                        collectedErrors.append(error)
                        errors.unlock()
                    }
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 60.0)
        XCTAssertTrue(
            collectedErrors.isEmpty,
            "Concurrent access produced errors: \(collectedErrors)"
        )
    }

    func testSecondaryHashIndex() throws {
        let systemConfig = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 4,
            enableCompression: true,
            readOnly: false,
            autoCheckpoint: true,
            checkpointThreshold: UInt64.max
        )
        let memDb = try Database(":memory:", systemConfig)
        let conn = try Connection(memDb)

        // Create table and data
        _ = try conn.query(
            "CREATE NODE TABLE HashIdxTest(id INT64, name STRING, email STRING, PRIMARY KEY(id))"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxTest {id: 1, name: 'Ali', email: 'ali@test.com'})"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxTest {id: 2, name: 'Veli', email: 'veli@test.com'})"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxTest {id: 3, name: 'Ayse', email: 'ayse@test.com'})"
        )

        // Create index on email
        try conn.createHashIndex(table: "HashIdxTest", property: "email")

        // Lookup existing value
        let results = try conn.lookupByIndex(
            table: "HashIdxTest", property: "email", value: "ali@test.com"
        )
        XCTAssertEqual(results.count, 1)

        // Lookup non-existent value
        let empty = try conn.lookupByIndex(
            table: "HashIdxTest", property: "email", value: "nobody@test.com"
        )
        XCTAssertEqual(empty.count, 0)

        // Drop index
        try conn.dropHashIndex(table: "HashIdxTest", property: "email")
    }

    /// Tests that QueryResult.close() can be called explicitly for eager cleanup.
    func testQueryResultExplicitClose() throws {
        let conn = try Connection(db)
        let result = try conn.query("MATCH (a:person) RETURN a.fName LIMIT 1;")
        XCTAssertTrue(result.hasNext())
        _ = try result.getNext()

        // Explicitly close — should not crash
        result.close()

        // Calling close again should be safe (idempotent)
        result.close()

        // The connection should still work after closing a result
        let result2 = try conn.query("RETURN 42;")
        XCTAssertTrue(result2.hasNext())
        let tuple = try result2.getNext()!
        let value = try tuple.getValue(0) as! Int64
        XCTAssertEqual(value, 42)
    }

    // MARK: - Secondary Hash Index Tests

    func testHashIndexAutoSyncOnInsert() throws {
        let systemConfig = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 4,
            enableCompression: true,
            readOnly: false,
            autoCheckpoint: true,
            checkpointThreshold: UInt64.max
        )
        let memDb = try Database(":memory:", systemConfig)
        let conn = try Connection(memDb)

        _ = try conn.query(
            "CREATE NODE TABLE HashIdxInsertTest(id INT64, email STRING, PRIMARY KEY(id))"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxInsertTest {id: 1, email: 'a@test.com'})"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxInsertTest {id: 2, email: 'b@test.com'})"
        )

        // Create index BEFORE inserting third node
        try conn.createHashIndex(table: "HashIdxInsertTest", property: "email")

        // Insert 3rd node AFTER index creation
        _ = try conn.query(
            "CREATE (p:HashIdxInsertTest {id: 3, email: 'c@test.com'})"
        )

        // Lookup the 3rd node by indexed property → should find it
        let results = try conn.lookupByIndex(
            table: "HashIdxInsertTest", property: "email", value: "c@test.com"
        )
        XCTAssertEqual(results.count, 1, "Post-index insert should be findable via index")

        // Original nodes should still be findable
        let resultsA = try conn.lookupByIndex(
            table: "HashIdxInsertTest", property: "email", value: "a@test.com"
        )
        XCTAssertEqual(resultsA.count, 1)

        try conn.dropHashIndex(table: "HashIdxInsertTest", property: "email")
    }

    func testHashIndexAutoSyncOnDelete() throws {
        let systemConfig = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 4,
            enableCompression: true,
            readOnly: false,
            autoCheckpoint: true,
            checkpointThreshold: UInt64.max
        )
        let memDb = try Database(":memory:", systemConfig)
        let conn = try Connection(memDb)

        _ = try conn.query(
            "CREATE NODE TABLE HashIdxDeleteTest(id INT64, email STRING, PRIMARY KEY(id))"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxDeleteTest {id: 1, email: 'del1@test.com'})"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxDeleteTest {id: 2, email: 'del2@test.com'})"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxDeleteTest {id: 3, email: 'del3@test.com'})"
        )

        try conn.createHashIndex(table: "HashIdxDeleteTest", property: "email")

        // Delete node with id=2
        _ = try conn.query(
            "MATCH (p:HashIdxDeleteTest) WHERE p.id = 2 DELETE p"
        )

        // Lookup deleted node's property → should return empty
        let deleted = try conn.lookupByIndex(
            table: "HashIdxDeleteTest", property: "email", value: "del2@test.com"
        )
        XCTAssertEqual(deleted.count, 0, "Deleted node should not be found via index")

        // Remaining nodes should still work
        let remaining1 = try conn.lookupByIndex(
            table: "HashIdxDeleteTest", property: "email", value: "del1@test.com"
        )
        XCTAssertEqual(remaining1.count, 1)

        let remaining3 = try conn.lookupByIndex(
            table: "HashIdxDeleteTest", property: "email", value: "del3@test.com"
        )
        XCTAssertEqual(remaining3.count, 1)

        try conn.dropHashIndex(table: "HashIdxDeleteTest", property: "email")
    }

    func testHashIndexAutoSyncOnUpdate() throws {
        let systemConfig = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 4,
            enableCompression: true,
            readOnly: false,
            autoCheckpoint: true,
            checkpointThreshold: UInt64.max
        )
        let memDb = try Database(":memory:", systemConfig)
        let conn = try Connection(memDb)

        _ = try conn.query(
            "CREATE NODE TABLE HashIdxUpdateTest(id INT64, email STRING, PRIMARY KEY(id))"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxUpdateTest {id: 1, email: 'old@test.com'})"
        )

        try conn.createHashIndex(table: "HashIdxUpdateTest", property: "email")

        // Update the email
        _ = try conn.query(
            "MATCH (p:HashIdxUpdateTest) WHERE p.id = 1 SET p.email = 'new@test.com'"
        )

        // Lookup old value → should return empty
        let oldResults = try conn.lookupByIndex(
            table: "HashIdxUpdateTest", property: "email", value: "old@test.com"
        )
        XCTAssertEqual(oldResults.count, 0, "Old value should not be found after update")

        // Lookup new value → should find the node
        let newResults = try conn.lookupByIndex(
            table: "HashIdxUpdateTest", property: "email", value: "new@test.com"
        )
        XCTAssertEqual(newResults.count, 1, "New value should be found after update")

        try conn.dropHashIndex(table: "HashIdxUpdateTest", property: "email")
    }

    func testHashIndexPersistenceAfterRestart() throws {
        let dbPath = NSTemporaryDirectory() + "kuzu_hash_idx_persist_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: true
        )

        // Phase 1: Create DB with data, close it
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)

            _ = try conn.query(
                "CREATE NODE TABLE HashIdxPersistTest(id INT64, email STRING, PRIMARY KEY(id))"
            )
            _ = try conn.query(
                "CREATE (p:HashIdxPersistTest {id: 1, email: 'persist1@test.com'})"
            )
            _ = try conn.query(
                "CREATE (p:HashIdxPersistTest {id: 2, email: 'persist2@test.com'})"
            )
        }

        // Phase 2: Reopen, create index on existing data, and verify it works
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)

            // Data should still be there
            let countResult = try conn.query(
                "MATCH (p:HashIdxPersistTest) RETURN count(p)"
            )
            XCTAssertTrue(countResult.hasNext())
            let countTuple = try countResult.getNext()!
            let count = try countTuple.getValue(0) as! Int64
            XCTAssertEqual(count, 2, "Data should persist after DB restart")

            // Create index on existing data
            try conn.createHashIndex(table: "HashIdxPersistTest", property: "email")

            // Lookup should work
            let results = try conn.lookupByIndex(
                table: "HashIdxPersistTest", property: "email", value: "persist1@test.com"
            )
            XCTAssertEqual(results.count, 1, "Index on persisted data should work")

            let results2 = try conn.lookupByIndex(
                table: "HashIdxPersistTest", property: "email", value: "persist2@test.com"
            )
            XCTAssertEqual(results2.count, 1, "Second entry should be found")

            let empty = try conn.lookupByIndex(
                table: "HashIdxPersistTest", property: "email", value: "nonexistent@test.com"
            )
            XCTAssertEqual(empty.count, 0)

            try conn.dropHashIndex(table: "HashIdxPersistTest", property: "email")
        }
    }

    func testHashIndexNonUniqueValues() throws {
        let systemConfig = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 4,
            enableCompression: true,
            readOnly: false,
            autoCheckpoint: true,
            checkpointThreshold: UInt64.max
        )
        let memDb = try Database(":memory:", systemConfig)
        let conn = try Connection(memDb)

        _ = try conn.query(
            "CREATE NODE TABLE HashIdxNonUniqueTest(id INT64, email STRING, PRIMARY KEY(id))"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxNonUniqueTest {id: 1, email: 'shared@test.com'})"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxNonUniqueTest {id: 2, email: 'shared@test.com'})"
        )
        _ = try conn.query(
            "CREATE (p:HashIdxNonUniqueTest {id: 3, email: 'shared@test.com'})"
        )

        try conn.createHashIndex(table: "HashIdxNonUniqueTest", property: "email")

        let results = try conn.lookupByIndex(
            table: "HashIdxNonUniqueTest", property: "email", value: "shared@test.com"
        )
        XCTAssertEqual(results.count, 3, "Non-unique index should return all 3 matches")

        try conn.dropHashIndex(table: "HashIdxNonUniqueTest", property: "email")
    }

    func testHashIndexInt64Property() throws {
        let systemConfig = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 4,
            enableCompression: true,
            readOnly: false,
            autoCheckpoint: true,
            checkpointThreshold: UInt64.max
        )
        let memDb = try Database(":memory:", systemConfig)
        let conn = try Connection(memDb)

        _ = try conn.query(
            "CREATE NODE TABLE HashIdxInt64Test(id INT64, age INT64, PRIMARY KEY(id))"
        )
        _ = try conn.query("CREATE (p:HashIdxInt64Test {id: 1, age: 25})")
        _ = try conn.query("CREATE (p:HashIdxInt64Test {id: 2, age: 30})")
        _ = try conn.query("CREATE (p:HashIdxInt64Test {id: 3, age: 25})")

        try conn.createHashIndex(table: "HashIdxInt64Test", property: "age")

        // Lookup by Int64 value
        let results25 = try conn.lookupByIndex(
            table: "HashIdxInt64Test", property: "age", value: Int64(25)
        )
        XCTAssertEqual(results25.count, 2, "Should find 2 nodes with age 25")

        let results30 = try conn.lookupByIndex(
            table: "HashIdxInt64Test", property: "age", value: Int64(30)
        )
        XCTAssertEqual(results30.count, 1, "Should find 1 node with age 30")

        let resultsNone = try conn.lookupByIndex(
            table: "HashIdxInt64Test", property: "age", value: Int64(99)
        )
        XCTAssertEqual(resultsNone.count, 0, "Should find no nodes with age 99")

        try conn.dropHashIndex(table: "HashIdxInt64Test", property: "age")
    }

    func testHashIndexEmptyTable() throws {
        let systemConfig = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 4,
            enableCompression: true,
            readOnly: false,
            autoCheckpoint: true,
            checkpointThreshold: UInt64.max
        )
        let memDb = try Database(":memory:", systemConfig)
        let conn = try Connection(memDb)

        _ = try conn.query(
            "CREATE NODE TABLE HashIdxEmptyTest(id INT64, email STRING, PRIMARY KEY(id))"
        )

        // Create index on empty table → should succeed
        try conn.createHashIndex(table: "HashIdxEmptyTest", property: "email")

        // Lookup any value → should return empty array
        let empty = try conn.lookupByIndex(
            table: "HashIdxEmptyTest", property: "email", value: "anything@test.com"
        )
        XCTAssertEqual(empty.count, 0, "Lookup on empty indexed table should return empty")

        // Insert a node → lookup should find it
        _ = try conn.query(
            "CREATE (p:HashIdxEmptyTest {id: 1, email: 'first@test.com'})"
        )
        let results = try conn.lookupByIndex(
            table: "HashIdxEmptyTest", property: "email", value: "first@test.com"
        )
        XCTAssertEqual(results.count, 1, "Should find node inserted after index creation on empty table")

        try conn.dropHashIndex(table: "HashIdxEmptyTest", property: "email")
    }

    func testHashIndexInvalidTableOrProperty() throws {
        let systemConfig = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 4,
            enableCompression: true,
            readOnly: false,
            autoCheckpoint: true,
            checkpointThreshold: UInt64.max
        )
        let memDb = try Database(":memory:", systemConfig)
        let conn = try Connection(memDb)

        // Try creating index on non-existent table → should throw error
        do {
            try conn.createHashIndex(table: "NonExistentTable", property: "email")
            XCTFail("Expected error for non-existent table")
        } catch let error as KuzuError {
            XCTAssertTrue(
                error.message.contains("NonExistentTable"),
                "Error should mention the invalid table name"
            )
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Create a table for the next test
        _ = try conn.query(
            "CREATE NODE TABLE HashIdxErrorTest(id INT64, email STRING, PRIMARY KEY(id))"
        )

        // Try creating index on non-existent property → should throw error
        do {
            try conn.createHashIndex(table: "HashIdxErrorTest", property: "nonExistentProp")
            XCTFail("Expected error for non-existent property")
        } catch let error as KuzuError {
            XCTAssertTrue(
                error.message.contains("nonExistentProp") || error.message.contains("property"),
                "Error should mention the invalid property: \(error.message)"
            )
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
