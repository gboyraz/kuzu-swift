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

    func testHashIndexBoolProperty() throws {
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

        _ = try conn.query("CREATE NODE TABLE Item(id INT64, name STRING, isUtility BOOL, PRIMARY KEY(id))")
        _ = try conn.query("CREATE (:Item {id: 1, name: 'Photo1', isUtility: true})")
        _ = try conn.query("CREATE (:Item {id: 2, name: 'Photo2', isUtility: false})")
        _ = try conn.query("CREATE (:Item {id: 3, name: 'Photo3', isUtility: true})")
        _ = try conn.query("CREATE (:Item {id: 4, name: 'Screenshot', isUtility: false})")

        // Create index on BOOL column
        try conn.createHashIndex(table: "Item", property: "isUtility")

        // Lookup true values — should find 2 (Photo1, Photo3)
        let result = try conn.query("CALL QUERY_HASH_INDEX('Item', 'isUtility', 'true') RETURN node_id")
        var trueCount = 0
        while result.hasNext() {
            let _ = try result.getNext()
            trueCount += 1
        }
        result.close()
        XCTAssertEqual(trueCount, 2)

        // Lookup false values — should find 2 (Photo2, Screenshot)
        let result2 = try conn.query("CALL QUERY_HASH_INDEX('Item', 'isUtility', 'false') RETURN node_id")
        var falseCount = 0
        while result2.hasNext() {
            let _ = try result2.getNext()
            falseCount += 1
        }
        result2.close()
        XCTAssertEqual(falseCount, 2)

        // createHashIndexIfNotExists should work without error
        let created = try conn.createHashIndexIfNotExists(table: "Item", property: "isUtility")
        XCTAssertFalse(created)  // already exists

        // Drop
        try conn.dropHashIndex(table: "Item", property: "isUtility")
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

    func testSecondaryIndexScanOptimizer() throws {
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
            "CREATE NODE TABLE IdxScanTest(id INT64, email STRING, name STRING, PRIMARY KEY(id))"
        )
        _ = try conn.query(
            "CREATE (p:IdxScanTest {id: 1, name: 'Ali', email: 'ali@test.com'})"
        )
        _ = try conn.query(
            "CREATE (p:IdxScanTest {id: 2, name: 'Veli', email: 'veli@test.com'})"
        )
        _ = try conn.query(
            "CREATE (p:IdxScanTest {id: 3, name: 'Ayse', email: 'ayse@test.com'})"
        )

        // Before index creation: EXPLAIN should show regular Scan
        let explainBefore = try conn.query(
            "EXPLAIN MATCH (p:IdxScanTest) WHERE p.email = 'ali@test.com' RETURN p.id, p.email, p.name"
        )
        var beforePlan = ""
        while explainBefore.hasNext() {
            if let tuple = try explainBefore.getNext() {
                let val = try tuple.getValue(0) as! String
                beforePlan += val
            }
        }
        XCTAssertFalse(
            beforePlan.contains("IndexScan"),
            "Before index creation, plan should NOT contain IndexScan"
        )

        // Create index on email
        try conn.createHashIndex(table: "IdxScanTest", property: "email")

        // After index creation: EXPLAIN should show IndexScan
        let explainAfter = try conn.query(
            "EXPLAIN MATCH (p:IdxScanTest) WHERE p.email = 'ali@test.com' RETURN p.id, p.email, p.name"
        )
        var afterPlan = ""
        while explainAfter.hasNext() {
            if let tuple = try explainAfter.getNext() {
                let val = try tuple.getValue(0) as! String
                afterPlan += val
            }
        }
        XCTAssertTrue(
            afterPlan.contains("IndexScan"),
            "After index creation, plan should contain IndexScan. Plan: \(afterPlan)"
        )

        // Run the actual query and verify correct result
        let result = try conn.query(
            "MATCH (p:IdxScanTest) WHERE p.email = 'ali@test.com' RETURN p.id, p.email, p.name"
        )
        XCTAssertTrue(result.hasNext())
        let tuple = try result.getNext()!
        let id = try tuple.getValue(0) as! Int64
        let email = try tuple.getValue(1) as! String
        let name = try tuple.getValue(2) as! String
        XCTAssertEqual(id, 1)
        XCTAssertEqual(email, "ali@test.com")
        XCTAssertEqual(name, "Ali")
        XCTAssertFalse(result.hasNext(), "Should return exactly one result")

        // Query for name (no index) should still work as full scan
        let nameResult = try conn.query(
            "MATCH (p:IdxScanTest) WHERE p.name = 'Veli' RETURN p.id"
        )
        XCTAssertTrue(nameResult.hasNext())
        let nameTuple = try nameResult.getNext()!
        let nameId = try nameTuple.getValue(0) as! Int64
        XCTAssertEqual(nameId, 2)

        try conn.dropHashIndex(table: "IdxScanTest", property: "email")
    }

    func testCreateHashIndexIfNotExists() throws {
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
            "CREATE NODE TABLE T1(id INT64, email STRING, PRIMARY KEY(id))"
        )

        // First call — creates
        let created = try conn.createHashIndexIfNotExists(table: "T1", property: "email")
        XCTAssertTrue(created)

        // Second call — already exists, no error
        let createdAgain = try conn.createHashIndexIfNotExists(table: "T1", property: "email")
        XCTAssertFalse(createdAgain)

        try conn.dropHashIndex(table: "T1", property: "email")
    }

    func testHasHashIndex() throws {
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
            "CREATE NODE TABLE T2(id INT64, name STRING, PRIMARY KEY(id))"
        )

        // No index yet
        let before = try conn.hasHashIndex(table: "T2", property: "name")
        XCTAssertFalse(before)

        // Create index
        try conn.createHashIndex(table: "T2", property: "name")

        // Now exists
        let after = try conn.hasHashIndex(table: "T2", property: "name")
        XCTAssertTrue(after)

        try conn.dropHashIndex(table: "T2", property: "name")
    }

    func testListHashIndexes() throws {
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
            "CREATE NODE TABLE T3(id INT64, name STRING, email STRING, age INT64, PRIMARY KEY(id))"
        )

        // No indexes
        let empty = try conn.listHashIndexes(table: "T3")
        XCTAssertTrue(empty.isEmpty)

        // Create 2 indexes
        try conn.createHashIndex(table: "T3", property: "name")
        try conn.createHashIndex(table: "T3", property: "email")

        let indexes = try conn.listHashIndexes(table: "T3")
        XCTAssertEqual(indexes.count, 2)
        XCTAssertTrue(indexes.contains("name"))
        XCTAssertTrue(indexes.contains("email"))

        try conn.dropHashIndex(table: "T3", property: "name")
        try conn.dropHashIndex(table: "T3", property: "email")
    }

    // MARK: - HNSW Vector Index Tests

    func testVectorIndexCreateAndSearch() throws {
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

        // Create table with 4-dim embedding (small for test)
        _ = try conn.query(
            "CREATE NODE TABLE Item(id INT64, name STRING, embedding FLOAT[4], PRIMARY KEY(id))"
        )

        // Insert nodes with embeddings
        _ = try conn.query("CREATE (:Item {id: 1, name: 'apple', embedding: [1.0, 0.0, 0.0, 0.0]})")
        _ = try conn.query("CREATE (:Item {id: 2, name: 'banana', embedding: [0.9, 0.1, 0.0, 0.0]})")
        _ = try conn.query("CREATE (:Item {id: 3, name: 'cherry', embedding: [0.0, 0.0, 1.0, 0.0]})")
        _ = try conn.query("CREATE (:Item {id: 4, name: 'date', embedding: [0.0, 0.0, 0.9, 0.1]})")
        _ = try conn.query("CREATE (:Item {id: 5, name: 'elderberry', embedding: [0.5, 0.5, 0.0, 0.0]})")

        // Create vector index
        try conn.createVectorIndex(table: "Item", indexName: "item_emb", property: "embedding", metric: "l2")

        // Search nearest to [1.0, 0.0, 0.0, 0.0] — should find apple first, then banana
        let results = try conn.searchNearest(
            table: "Item", indexName: "item_emb", queryVector: [1.0, 0.0, 0.0, 0.0], k: 3
        )
        XCTAssertEqual(results.count, 3)
        // Results should be sorted by distance ascending
        XCTAssertTrue(results[0].distance <= results[1].distance)
        XCTAssertTrue(results[1].distance <= results[2].distance)

        // Drop index
        try conn.dropVectorIndex(table: "Item", indexName: "item_emb")
    }

    func testVectorIndexIfNotExists() throws {
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
            "CREATE NODE TABLE V(id INT64, emb FLOAT[4], PRIMARY KEY(id))"
        )
        _ = try conn.query("CREATE (:V {id: 1, emb: [1.0, 0.0, 0.0, 0.0]})")

        let created = try conn.createVectorIndexIfNotExists(
            table: "V", indexName: "idx", property: "emb"
        )
        XCTAssertTrue(created)

        let createdAgain = try conn.createVectorIndexIfNotExists(
            table: "V", indexName: "idx", property: "emb"
        )
        XCTAssertFalse(createdAgain)
    }

    // MARK: - Composite Hash Index Tests

    private func makeCompositeTestDb() throws -> (Database, Connection) {
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
        _ = try conn.query("""
            CREATE NODE TABLE Person(
                id INT64, firstName STRING, lastName STRING, city STRING, age INT64,
                PRIMARY KEY(id))
        """)
        _ = try conn.query("CREATE (:Person {id:1, firstName:'Ali', lastName:'Yilmaz', city:'Istanbul', age:30})")
        _ = try conn.query("CREATE (:Person {id:2, firstName:'Veli', lastName:'Kaya', city:'Ankara', age:25})")
        _ = try conn.query("CREATE (:Person {id:3, firstName:'Ayse', lastName:'Demir', city:'Istanbul', age:28})")
        _ = try conn.query("CREATE (:Person {id:4, firstName:'Ali', lastName:'Kaya', city:'Izmir', age:35})")
        return (memDb, conn)
    }

    // 1. Basic composite create/lookup/drop
    func testCompositeIndexBasicCreateLookupDrop() throws {
        let (_, conn) = try makeCompositeTestDb()
        try conn.createCompositeIndex(table: "Person", properties: ["firstName", "lastName"])
        let results = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Ali", "Yilmaz"])
        XCTAssertEqual(results.count, 1)
        // Drop composite index
        try conn.dropHashIndex(table: "Person", property: "firstName,lastName")
        // Verify index is gone
        let indexes = try conn.listHashIndexes(table: "Person")
        XCTAssertFalse(indexes.contains("firstName,lastName"))
    }

    // 2. 2-property composite (firstName + lastName)
    func testCompositeIndex2Property() throws {
        let (_, conn) = try makeCompositeTestDb()
        try conn.createCompositeIndex(table: "Person", properties: ["firstName", "lastName"])
        // Ali Yilmaz exists
        let r1 = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Ali", "Yilmaz"])
        XCTAssertEqual(r1.count, 1)
        // Ali Kaya also exists
        let r2 = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Ali", "Kaya"])
        XCTAssertEqual(r2.count, 1)
        // Ali Demir does NOT exist
        let r3 = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Ali", "Demir"])
        XCTAssertEqual(r3.count, 0)
        try conn.dropHashIndex(table: "Person", property: "firstName,lastName")
    }

    // 3. 3-property composite (firstName + lastName + city)
    func testCompositeIndex3Property() throws {
        let (_, conn) = try makeCompositeTestDb()
        try conn.createCompositeIndex(table: "Person", properties: ["firstName", "lastName", "city"])
        let results = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName", "city"],
            values: ["Ali", "Yilmaz", "Istanbul"])
        XCTAssertEqual(results.count, 1)
        // Wrong city
        let empty = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName", "city"],
            values: ["Ali", "Yilmaz", "Ankara"])
        XCTAssertEqual(empty.count, 0)
        try conn.dropHashIndex(table: "Person", property: "firstName,lastName,city")
    }

    // 4. Non-unique composite (multiple nodes same combo)
    func testCompositeIndexNonUnique() throws {
        let (_, conn) = try makeCompositeTestDb()
        // Add another Ali Yilmaz
        _ = try conn.query("CREATE (:Person {id:5, firstName:'Ali', lastName:'Yilmaz', city:'Bursa', age:40})")
        try conn.createCompositeIndex(table: "Person", properties: ["firstName", "lastName"])
        let results = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Ali", "Yilmaz"])
        XCTAssertEqual(results.count, 2)
        try conn.dropHashIndex(table: "Person", property: "firstName,lastName")
    }

    // 5. Insert sync — new node appears in composite index
    func testCompositeIndexInsertSync() throws {
        let (_, conn) = try makeCompositeTestDb()
        try conn.createCompositeIndex(table: "Person", properties: ["firstName", "lastName"])
        // Insert new node
        _ = try conn.query("CREATE (:Person {id:6, firstName:'Fatma', lastName:'Ozturk', city:'Antalya', age:22})")
        let results = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Fatma", "Ozturk"])
        XCTAssertEqual(results.count, 1)
        try conn.dropHashIndex(table: "Person", property: "firstName,lastName")
    }

    // 6. Delete sync — deleted node removed from composite index
    func testCompositeIndexDeleteSync() throws {
        let (_, conn) = try makeCompositeTestDb()
        try conn.createCompositeIndex(table: "Person", properties: ["firstName", "lastName"])
        // Verify Ali Yilmaz exists
        let before = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Ali", "Yilmaz"])
        XCTAssertEqual(before.count, 1)
        // Delete Ali Yilmaz
        _ = try conn.query("MATCH (p:Person) WHERE p.id = 1 DELETE p")
        let after = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Ali", "Yilmaz"])
        XCTAssertEqual(after.count, 0)
        try conn.dropHashIndex(table: "Person", property: "firstName,lastName")
    }

    // 7. Update sync — property change updates composite index
    func testCompositeIndexUpdateSync() throws {
        let (_, conn) = try makeCompositeTestDb()
        try conn.createCompositeIndex(table: "Person", properties: ["firstName", "lastName"])
        // Verify current combo exists
        let before = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Ali", "Yilmaz"])
        XCTAssertEqual(before.count, 1)
        // Update lastName from Yilmaz to Ozcan
        _ = try conn.query("MATCH (p:Person) WHERE p.id = 1 SET p.lastName = 'Ozcan'")
        // Old combo should be gone
        let afterOld = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Ali", "Yilmaz"])
        XCTAssertEqual(afterOld.count, 0)
        // New combo should exist
        let afterNew = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "lastName"], values: ["Ali", "Ozcan"])
        XCTAssertEqual(afterNew.count, 1)
        try conn.dropHashIndex(table: "Person", property: "firstName,lastName")
    }

    // 8. Mixed types — string + int64 composite
    func testCompositeIndexMixedTypes() throws {
        let (_, conn) = try makeCompositeTestDb()
        try conn.createCompositeIndex(table: "Person", properties: ["firstName", "age"])
        // Ali,30 exists
        let results = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "age"], values: ["Ali", "30"])
        XCTAssertEqual(results.count, 1)
        // Ali,25 does NOT exist
        let empty = try conn.lookupByCompositeIndex(
            table: "Person", properties: ["firstName", "age"], values: ["Ali", "25"])
        XCTAssertEqual(empty.count, 0)
        try conn.dropHashIndex(table: "Person", property: "firstName,age")
    }

    // 9. Null property handling — composite key with null skips entry
    func testCompositeIndexNullProperty() throws {
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
        _ = try conn.query("""
            CREATE NODE TABLE NullTest(
                id INT64, firstName STRING, lastName STRING, PRIMARY KEY(id))
        """)
        _ = try conn.query("CREATE (:NullTest {id:1, firstName:'Ali', lastName:'Yilmaz'})")
        // Insert node with null lastName
        _ = try conn.query("CREATE (:NullTest {id:2, firstName:'Veli'})")
        try conn.createCompositeIndex(table: "NullTest", properties: ["firstName", "lastName"])
        // Ali,Yilmaz should be found
        let r1 = try conn.lookupByCompositeIndex(
            table: "NullTest", properties: ["firstName", "lastName"], values: ["Ali", "Yilmaz"])
        XCTAssertEqual(r1.count, 1)
        // Veli with null lastName should NOT be indexed (null skips)
        let r2 = try conn.lookupByCompositeIndex(
            table: "NullTest", properties: ["firstName", "lastName"], values: ["Veli", ""])
        XCTAssertEqual(r2.count, 0)
        try conn.dropHashIndex(table: "NullTest", property: "firstName,lastName")
    }

    // Test createCompositeIndexIfNotExists
    func testCreateCompositeIndexIfNotExists() throws {
        let (_, conn) = try makeCompositeTestDb()
        let created = try conn.createCompositeIndexIfNotExists(
            table: "Person", properties: ["firstName", "lastName"])
        XCTAssertTrue(created)
        let createdAgain = try conn.createCompositeIndexIfNotExists(
            table: "Person", properties: ["firstName", "lastName"])
        XCTAssertFalse(createdAgain)
        try conn.dropHashIndex(table: "Person", property: "firstName,lastName")
    }

    // MARK: - WAL Recovery Tests

    /// Test that a hash index survives DB close and reopen (with checkpoint).
    func testHashIndexSurvivesReopen() throws {
        let dbPath = NSTemporaryDirectory() + "kuzu_wal_reopen_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: true
        )

        // Phase 1: Create table, insert data, create index, close DB
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            _ = try conn.query(
                "CREATE NODE TABLE WalTest(id INT64, email STRING, PRIMARY KEY(id))")
            _ = try conn.query("CREATE (:WalTest {id:1, email:'a@test.com'})")
            _ = try conn.query("CREATE (:WalTest {id:2, email:'b@test.com'})")
            _ = try conn.query("CREATE (:WalTest {id:3, email:'c@test.com'})")
            try conn.createHashIndex(table: "WalTest", property: "email")
            // Verify index works before close
            let r = try conn.lookupByIndex(table: "WalTest", property: "email", value: "a@test.com")
            XCTAssertEqual(r.count, 1)
        }

        // Phase 2: Reopen DB and verify index still works
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)

            // First verify data is there
            let countResult = try conn.query("MATCH (p:WalTest) RETURN count(p)")
            XCTAssertTrue(countResult.hasNext())
            let countTuple = try countResult.getNext()!
            let count = try countTuple.getValue(0) as! Int64
            XCTAssertEqual(count, 3, "Data should persist after restart")

            let has = try conn.hasHashIndex(table: "WalTest", property: "email")
            XCTAssertTrue(has, "Index should exist after reopen")
            let r1 = try conn.lookupByIndex(table: "WalTest", property: "email", value: "a@test.com")
            XCTAssertEqual(r1.count, 1, "Should find 'a@test.com' after reopen")
            let r2 = try conn.lookupByIndex(table: "WalTest", property: "email", value: "b@test.com")
            XCTAssertEqual(r2.count, 1, "Should find 'b@test.com' after reopen")
            let r3 = try conn.lookupByIndex(table: "WalTest", property: "email", value: "nonexistent@test.com")
            XCTAssertEqual(r3.count, 0, "Should not find nonexistent value")
            try conn.dropHashIndex(table: "WalTest", property: "email")
        }
    }

    /// Test that a hash index survives DB close without explicit checkpoint (WAL recovery).
    func testHashIndexSurvivesReopenWithoutCheckpoint() throws {
        let dbPath = NSTemporaryDirectory() + "kuzu_wal_nocp_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        // Disable auto-checkpoint so index creation is only in WAL
        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: false
        )

        // Phase 1: Create table, insert data, create index (no checkpoint)
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            _ = try conn.query(
                "CREATE NODE TABLE WalNoCp(id INT64, name STRING, PRIMARY KEY(id))")
            _ = try conn.query("CREATE (:WalNoCp {id:1, name:'Alice'})")
            _ = try conn.query("CREATE (:WalNoCp {id:2, name:'Bob'})")
            try conn.createHashIndex(table: "WalNoCp", property: "name")
            let r = try conn.lookupByIndex(table: "WalNoCp", property: "name", value: "Alice")
            XCTAssertEqual(r.count, 1)
        }

        // Phase 2: Reopen — WAL recovery should rebuild the index
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            let has = try conn.hasHashIndex(table: "WalNoCp", property: "name")
            XCTAssertTrue(has, "Index should exist after WAL recovery")
            let r1 = try conn.lookupByIndex(table: "WalNoCp", property: "name", value: "Alice")
            XCTAssertEqual(r1.count, 1, "Should find 'Alice' after WAL recovery")
            let r2 = try conn.lookupByIndex(table: "WalNoCp", property: "name", value: "Bob")
            XCTAssertEqual(r2.count, 1, "Should find 'Bob' after WAL recovery")
            try conn.dropHashIndex(table: "WalNoCp", property: "name")
        }
    }

    /// Test that dropping a hash index survives DB close and reopen.
    func testDropHashIndexSurvivesReopen() throws {
        let dbPath = NSTemporaryDirectory() + "kuzu_wal_drop_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: true
        )

        // Phase 1: Create table, data, index, then drop the index
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            _ = try conn.query(
                "CREATE NODE TABLE WalDrop(id INT64, email STRING, PRIMARY KEY(id))")
            _ = try conn.query("CREATE (:WalDrop {id:1, email:'x@test.com'})")
            try conn.createHashIndex(table: "WalDrop", property: "email")
            let has = try conn.hasHashIndex(table: "WalDrop", property: "email")
            XCTAssertTrue(has)
            try conn.dropHashIndex(table: "WalDrop", property: "email")
            let hasAfter = try conn.hasHashIndex(table: "WalDrop", property: "email")
            XCTAssertFalse(hasAfter)
        }

        // Phase 2: Reopen and verify index is still gone
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            let has = try conn.hasHashIndex(table: "WalDrop", property: "email")
            XCTAssertFalse(has, "Dropped index should not exist after reopen")
        }
    }

    /// Test that a composite index survives DB close and reopen.
    func testCompositeIndexSurvivesReopen() throws {
        let dbPath = NSTemporaryDirectory() + "kuzu_wal_composite_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: true
        )

        // Phase 1: Create table, data, composite index
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            _ = try conn.query("""
                CREATE NODE TABLE WalComp(
                    id INT64, firstName STRING, lastName STRING, PRIMARY KEY(id))
            """)
            _ = try conn.query("CREATE (:WalComp {id:1, firstName:'Ali', lastName:'Yilmaz'})")
            _ = try conn.query("CREATE (:WalComp {id:2, firstName:'Veli', lastName:'Kaya'})")
            _ = try conn.query("CREATE (:WalComp {id:3, firstName:'Ali', lastName:'Kaya'})")
            try conn.createCompositeIndex(table: "WalComp", properties: ["firstName", "lastName"])
            let r = try conn.lookupByCompositeIndex(
                table: "WalComp", properties: ["firstName", "lastName"], values: ["Ali", "Yilmaz"])
            XCTAssertEqual(r.count, 1)
        }

        // Phase 2: Reopen and verify composite index works
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            let has = try conn.hasHashIndex(table: "WalComp", property: "firstName,lastName")
            XCTAssertTrue(has, "Composite index should exist after reopen")
            let r1 = try conn.lookupByCompositeIndex(
                table: "WalComp", properties: ["firstName", "lastName"], values: ["Ali", "Yilmaz"])
            XCTAssertEqual(r1.count, 1, "Should find Ali Yilmaz after reopen")
            let r2 = try conn.lookupByCompositeIndex(
                table: "WalComp", properties: ["firstName", "lastName"], values: ["Veli", "Kaya"])
            XCTAssertEqual(r2.count, 1, "Should find Veli Kaya after reopen")
            let r3 = try conn.lookupByCompositeIndex(
                table: "WalComp", properties: ["firstName", "lastName"], values: ["Ali", "Kaya"])
            XCTAssertEqual(r3.count, 1, "Should find Ali Kaya after reopen")
            try conn.dropHashIndex(table: "WalComp", property: "firstName,lastName")
        }
    }

    /// Test that a BOOL property index survives DB close and reopen.
    func testBoolIndexSurvivesReopen() throws {
        let dbPath = NSTemporaryDirectory() + "kuzu_wal_bool_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: true
        )

        // Phase 1: Create table with BOOL, data, index
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            _ = try conn.query(
                "CREATE NODE TABLE WalBool(id INT64, active BOOL, PRIMARY KEY(id))")
            _ = try conn.query("CREATE (:WalBool {id:1, active:true})")
            _ = try conn.query("CREATE (:WalBool {id:2, active:false})")
            _ = try conn.query("CREATE (:WalBool {id:3, active:true})")
            try conn.createHashIndex(table: "WalBool", property: "active")
            let r = try conn.lookupByIndex(table: "WalBool", property: "active", value: "true")
            XCTAssertEqual(r.count, 2)
        }

        // Phase 2: Reopen and verify BOOL index works
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            let has = try conn.hasHashIndex(table: "WalBool", property: "active")
            XCTAssertTrue(has, "Bool index should exist after reopen")
            let rTrue = try conn.lookupByIndex(table: "WalBool", property: "active", value: "true")
            XCTAssertEqual(rTrue.count, 2, "Should find 2 active=true after reopen")
            let rFalse = try conn.lookupByIndex(table: "WalBool", property: "active", value: "false")
            XCTAssertEqual(rFalse.count, 1, "Should find 1 active=false after reopen")
            try conn.dropHashIndex(table: "WalBool", property: "active")
        }
    }

    // MARK: - Range Index Tests

    private func makeRangeTestDb() throws -> (Database, Connection) {
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
        _ = try conn.query("""
            CREATE NODE TABLE RangeTest(
                id INT64, name STRING, age INT64, score DOUBLE, PRIMARY KEY(id))
        """)
        _ = try conn.query("CREATE (:RangeTest {id:1, name:'Alice', age:25, score:85.5})")
        _ = try conn.query("CREATE (:RangeTest {id:2, name:'Bob', age:30, score:92.0})")
        _ = try conn.query("CREATE (:RangeTest {id:3, name:'Charlie', age:35, score:78.3})")
        _ = try conn.query("CREATE (:RangeTest {id:4, name:'Diana', age:28, score:95.1})")
        _ = try conn.query("CREATE (:RangeTest {id:5, name:'Eve', age:22, score:88.7})")
        return (memDb, conn)
    }

    func testRangeIndexBasic() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "age")
        // Query range 25..30 (inclusive)
        let results = try conn.queryRange(table: "RangeTest", property: "age", min: "25", max: "30")
        // Should match Alice(25), Bob(30), Diana(28)
        XCTAssertEqual(results.count, 3)
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    func testRangeIndexHalfOpenMin() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "age")
        // age >= 30
        let results = try conn.queryRange(table: "RangeTest", property: "age", min: "30")
        // Should match Bob(30), Charlie(35)
        XCTAssertEqual(results.count, 2)
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    func testRangeIndexHalfOpenMax() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "age")
        // age <= 25
        let results = try conn.queryRange(table: "RangeTest", property: "age", max: "25")
        // Should match Alice(25), Eve(22)
        XCTAssertEqual(results.count, 2)
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    func testRangeIndexEmptyResult() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "age")
        // age 100..200 — no matches
        let results = try conn.queryRange(table: "RangeTest", property: "age", min: "100", max: "200")
        XCTAssertEqual(results.count, 0)
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    func testRangeIndexNonUnique() throws {
        let (_, conn) = try makeRangeTestDb()
        // Add another person with age 25
        _ = try conn.query("CREATE (:RangeTest {id:6, name:'Frank', age:25, score:70.0})")
        try conn.createRangeIndex(table: "RangeTest", property: "age")
        // Query exactly 25..25
        let results = try conn.queryRange(table: "RangeTest", property: "age", min: "25", max: "25")
        // Alice(25) + Frank(25)
        XCTAssertEqual(results.count, 2)
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    func testRangeIndexInsertDeleteSync() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "age")
        // Insert new node
        _ = try conn.query("CREATE (:RangeTest {id:7, name:'Grace', age:27, score:91.0})")
        let afterInsert = try conn.queryRange(table: "RangeTest", property: "age", min: "27", max: "27")
        XCTAssertEqual(afterInsert.count, 1)
        // Delete Grace
        _ = try conn.query("MATCH (p:RangeTest) WHERE p.id = 7 DELETE p")
        let afterDelete = try conn.queryRange(table: "RangeTest", property: "age", min: "27", max: "27")
        XCTAssertEqual(afterDelete.count, 0)
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    func testRangeIndexUpdateSync() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "age")
        // Alice is 25, update to 40
        _ = try conn.query("MATCH (p:RangeTest) WHERE p.id = 1 SET p.age = 40")
        // Old value should be gone
        let oldRange = try conn.queryRange(table: "RangeTest", property: "age", min: "25", max: "25")
        XCTAssertEqual(oldRange.count, 0)
        // New value should appear
        let newRange = try conn.queryRange(table: "RangeTest", property: "age", min: "40", max: "40")
        XCTAssertEqual(newRange.count, 1)
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    func testRangeIndexDoubleType() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "score")
        // score 85.0..92.0 → Alice(85.5), Bob(92.0), Eve(88.7)
        let results = try conn.queryRange(table: "RangeTest", property: "score", min: "85.0", max: "92.0")
        XCTAssertEqual(results.count, 3)
        try conn.dropRangeIndex(table: "RangeTest", property: "score")
    }

    func testRangeIndexStringType() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "name")
        // Lexicographic: "Alice".."Charlie" → Alice, Bob, Charlie
        let results = try conn.queryRange(table: "RangeTest", property: "name", min: "Alice", max: "Charlie")
        XCTAssertEqual(results.count, 3)
        try conn.dropRangeIndex(table: "RangeTest", property: "name")
    }

    func testRangeIndexSurvivesReopen() throws {
        let dbPath = NSTemporaryDirectory() + "kuzu_range_idx_reopen_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: true
        )

        // Phase 1: Create table, data, range index
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            _ = try conn.query(
                "CREATE NODE TABLE RangeReopen(id INT64, age INT64, PRIMARY KEY(id))")
            _ = try conn.query("CREATE (:RangeReopen {id:1, age:20})")
            _ = try conn.query("CREATE (:RangeReopen {id:2, age:30})")
            _ = try conn.query("CREATE (:RangeReopen {id:3, age:40})")
            try conn.createRangeIndex(table: "RangeReopen", property: "age")
            let r = try conn.queryRange(table: "RangeReopen", property: "age", min: "25", max: "35")
            XCTAssertEqual(r.count, 1, "Should find age=30 before close")
        }

        // Phase 2: Reopen and verify
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            let has = try conn.hasRangeIndex(table: "RangeReopen", property: "age")
            XCTAssertTrue(has, "Range index should exist after reopen")
            let r = try conn.queryRange(table: "RangeReopen", property: "age", min: "25", max: "35")
            XCTAssertEqual(r.count, 1, "Should find age=30 after reopen")
            try conn.dropRangeIndex(table: "RangeReopen", property: "age")
        }
    }

    func testRangeIndexIfNotExists() throws {
        let (_, conn) = try makeRangeTestDb()
        // First call — creates
        let created = try conn.createRangeIndexIfNotExists(table: "RangeTest", property: "age")
        XCTAssertTrue(created)
        // Second call — already exists
        let createdAgain = try conn.createRangeIndexIfNotExists(table: "RangeTest", property: "age")
        XCTAssertFalse(createdAgain)
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    func testRangeIndexEmptyTable() throws {
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
            "CREATE NODE TABLE RangeEmpty(id INT64, val INT64, PRIMARY KEY(id))")
        // Create index on empty table
        try conn.createRangeIndex(table: "RangeEmpty", property: "val")
        // Query should return empty
        let results = try conn.queryRange(table: "RangeEmpty", property: "val", min: "0", max: "100")
        XCTAssertEqual(results.count, 0)
        // Verify index listed
        let indexes = try conn.listRangeIndexes(table: "RangeEmpty")
        XCTAssertEqual(indexes.count, 1)
        XCTAssertEqual(indexes[0], "val")
        try conn.dropRangeIndex(table: "RangeEmpty", property: "val")
    }

    // MARK: - Range Index Optimizer Tests

    func testRangeIndexOptimizerSinglePredicate() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "age")
        // WHERE p.age > 30 should use range index scan
        let result = try conn.query("MATCH (p:RangeTest) WHERE p.age > 30 RETURN p.name ORDER BY p.name")
        var names: [String] = []
        while result.hasNext() {
            if let tuple = try result.getNext() {
                if let name = try tuple.getValue(0) as? String {
                    names.append(name)
                }
            }
        }
        result.close()
        XCTAssertEqual(names, ["Charlie"]) // age 35
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    func testRangeIndexOptimizerDualPredicate() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "age")
        // WHERE p.age >= 25 AND p.age <= 30 should use a single range index scan
        let result = try conn.query("MATCH (p:RangeTest) WHERE p.age >= 25 AND p.age <= 30 RETURN p.name ORDER BY p.name")
        var names: [String] = []
        while result.hasNext() {
            if let tuple = try result.getNext() {
                if let name = try tuple.getValue(0) as? String {
                    names.append(name)
                }
            }
        }
        result.close()
        // Alice(25), Bob(30), Diana(28)
        XCTAssertEqual(names, ["Alice", "Bob", "Diana"])
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    func testRangeIndexOptimizerNoIndexFallback() throws {
        let (_, conn) = try makeRangeTestDb()
        // No range index — should still work via regular scan + filter
        let result = try conn.query("MATCH (p:RangeTest) WHERE p.age > 30 RETURN p.name")
        var names: [String] = []
        while result.hasNext() {
            if let tuple = try result.getNext() {
                if let name = try tuple.getValue(0) as? String {
                    names.append(name)
                }
            }
        }
        result.close()
        XCTAssertEqual(names.count, 1) // Charlie(35)
    }

    func testRangeIndexOptimizerReversedPredicate() throws {
        let (_, conn) = try makeRangeTestDb()
        try conn.createRangeIndex(table: "RangeTest", property: "age")
        // WHERE 30 < p.age — reversed operand order, optimizer should still detect it
        let result = try conn.query("MATCH (p:RangeTest) WHERE 30 < p.age RETURN p.name ORDER BY p.name")
        var names: [String] = []
        while result.hasNext() {
            if let tuple = try result.getNext() {
                if let name = try tuple.getValue(0) as? String {
                    names.append(name)
                }
            }
        }
        result.close()
        XCTAssertEqual(names, ["Charlie"]) // age 35
        try conn.dropRangeIndex(table: "RangeTest", property: "age")
    }

    // MARK: - Unique Index Tests

    func testUniqueIndexBasic() throws {
        let memDb = try Database(":memory:")
        let conn = try Connection(memDb)
        _ = try conn.query("CREATE NODE TABLE UniqueTest(id INT64, email STRING, PRIMARY KEY(id))")
        _ = try conn.query("CREATE (:UniqueTest {id:1, email:'a@test.com'})")
        _ = try conn.query("CREATE (:UniqueTest {id:2, email:'b@test.com'})")
        try conn.createUniqueIndex(table: "UniqueTest", property: "email")
        let r = try conn.lookupUnique(table: "UniqueTest", property: "email", value: "a@test.com")
        XCTAssertNotNil(r)
        let empty = try conn.lookupUnique(table: "UniqueTest", property: "email", value: "nobody@test.com")
        XCTAssertNil(empty)
        try conn.dropUniqueIndex(table: "UniqueTest", property: "email")
    }

    func testUniqueIndexDuplicateInsertFails() throws {
        let memDb = try Database(":memory:")
        let conn = try Connection(memDb)
        _ = try conn.query("CREATE NODE TABLE UniqueInsert(id INT64, email STRING, PRIMARY KEY(id))")
        _ = try conn.query("CREATE (:UniqueInsert {id:1, email:'dup@test.com'})")
        try conn.createUniqueIndex(table: "UniqueInsert", property: "email")
        // Inserting a duplicate should fail
        XCTAssertThrowsError(try conn.query("CREATE (:UniqueInsert {id:2, email:'dup@test.com'})")) { error in
            XCTAssertTrue("\(error)".contains("Unique constraint violation"))
        }
        try conn.dropUniqueIndex(table: "UniqueInsert", property: "email")
    }

    func testUniqueIndexDuplicateUpdateFails() throws {
        let memDb = try Database(":memory:")
        let conn = try Connection(memDb)
        _ = try conn.query("CREATE NODE TABLE UniqueUpdate(id INT64, email STRING, PRIMARY KEY(id))")
        _ = try conn.query("CREATE (:UniqueUpdate {id:1, email:'first@test.com'})")
        _ = try conn.query("CREATE (:UniqueUpdate {id:2, email:'second@test.com'})")
        try conn.createUniqueIndex(table: "UniqueUpdate", property: "email")
        // Updating to a value that already exists on another row should fail
        XCTAssertThrowsError(try conn.query("MATCH (p:UniqueUpdate) WHERE p.id = 2 SET p.email = 'first@test.com'")) { error in
            XCTAssertTrue("\(error)".contains("Unique constraint violation"))
        }
        try conn.dropUniqueIndex(table: "UniqueUpdate", property: "email")
    }

    func testUniqueIndexUpdateSameRowOk() throws {
        let memDb = try Database(":memory:")
        let conn = try Connection(memDb)
        _ = try conn.query("CREATE NODE TABLE UniqueSame(id INT64, email STRING, PRIMARY KEY(id))")
        _ = try conn.query("CREATE (:UniqueSame {id:1, email:'same@test.com'})")
        try conn.createUniqueIndex(table: "UniqueSame", property: "email")
        // Updating a row to its own current value should succeed
        _ = try conn.query("MATCH (p:UniqueSame) WHERE p.id = 1 SET p.email = 'same@test.com'")
        let r = try conn.lookupUnique(table: "UniqueSame", property: "email", value: "same@test.com")
        XCTAssertNotNil(r)
        try conn.dropUniqueIndex(table: "UniqueSame", property: "email")
    }

    func testUniqueIndexDeleteReinsert() throws {
        let memDb = try Database(":memory:")
        let conn = try Connection(memDb)
        _ = try conn.query("CREATE NODE TABLE UniqueReins(id INT64, email STRING, PRIMARY KEY(id))")
        _ = try conn.query("CREATE (:UniqueReins {id:1, email:'reuse@test.com'})")
        try conn.createUniqueIndex(table: "UniqueReins", property: "email")
        // Delete and re-insert same value
        _ = try conn.query("MATCH (p:UniqueReins) WHERE p.id = 1 DELETE p")
        _ = try conn.query("CREATE (:UniqueReins {id:2, email:'reuse@test.com'})")
        let r = try conn.lookupUnique(table: "UniqueReins", property: "email", value: "reuse@test.com")
        XCTAssertNotNil(r)
        try conn.dropUniqueIndex(table: "UniqueReins", property: "email")
    }

    func testUniqueIndexNullSkip() throws {
        let memDb = try Database(":memory:")
        let conn = try Connection(memDb)
        _ = try conn.query("CREATE NODE TABLE UniqueNull(id INT64, email STRING, PRIMARY KEY(id))")
        _ = try conn.query("CREATE (:UniqueNull {id:1})")
        _ = try conn.query("CREATE (:UniqueNull {id:2})")
        // Both have null email — should not conflict
        try conn.createUniqueIndex(table: "UniqueNull", property: "email")
        let r = try conn.lookupUnique(table: "UniqueNull", property: "email", value: "anything")
        XCTAssertNil(r)
        try conn.dropUniqueIndex(table: "UniqueNull", property: "email")
    }

    func testUniqueIndexSurvivesReopen() throws {
        let dbPath = NSTemporaryDirectory() + "kuzu_unique_reopen_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let config = SystemConfig(bufferPoolSize: 256 * 1024 * 1024, maxNumThreads: 1, autoCheckpoint: true)
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            _ = try conn.query("CREATE NODE TABLE UniqueReopen(id INT64, email STRING, PRIMARY KEY(id))")
            _ = try conn.query("CREATE (:UniqueReopen {id:1, email:'persist@test.com'})")
            try conn.createUniqueIndex(table: "UniqueReopen", property: "email")
            let r = try conn.lookupUnique(table: "UniqueReopen", property: "email", value: "persist@test.com")
            XCTAssertNotNil(r)
        }
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            let has = try conn.hasUniqueIndex(table: "UniqueReopen", property: "email")
            XCTAssertTrue(has)
            let r = try conn.lookupUnique(table: "UniqueReopen", property: "email", value: "persist@test.com")
            XCTAssertNotNil(r)
            // Duplicate should still be rejected after reopen
            XCTAssertThrowsError(try conn.query("CREATE (:UniqueReopen {id:2, email:'persist@test.com'})")) { error in
                XCTAssertTrue("\(error)".contains("Unique constraint violation"))
            }
            try conn.dropUniqueIndex(table: "UniqueReopen", property: "email")
        }
    }

    func testUniqueIndexEmptyTable() throws {
        let memDb = try Database(":memory:")
        let conn = try Connection(memDb)
        _ = try conn.query("CREATE NODE TABLE UniqueEmpty(id INT64, email STRING, PRIMARY KEY(id))")
        try conn.createUniqueIndex(table: "UniqueEmpty", property: "email")
        let r = try conn.lookupUnique(table: "UniqueEmpty", property: "email", value: "anything")
        XCTAssertNil(r)
        // Insert should work on empty table
        _ = try conn.query("CREATE (:UniqueEmpty {id:1, email:'first@test.com'})")
        let r2 = try conn.lookupUnique(table: "UniqueEmpty", property: "email", value: "first@test.com")
        XCTAssertNotNil(r2)
        try conn.dropUniqueIndex(table: "UniqueEmpty", property: "email")
    }

    func testUniqueIndexMultipleProperties() throws {
        let memDb = try Database(":memory:")
        let conn = try Connection(memDb)
        _ = try conn.query("CREATE NODE TABLE UniqueMulti(id INT64, email STRING, username STRING, PRIMARY KEY(id))")
        _ = try conn.query("CREATE (:UniqueMulti {id:1, email:'a@test.com', username:'user_a'})")
        _ = try conn.query("CREATE (:UniqueMulti {id:2, email:'b@test.com', username:'user_b'})")
        try conn.createUniqueIndex(table: "UniqueMulti", property: "email")
        try conn.createUniqueIndex(table: "UniqueMulti", property: "username")
        let indexes = try conn.listUniqueIndexes(table: "UniqueMulti")
        XCTAssertEqual(indexes.sorted(), ["email", "username"])
        // Duplicate email should fail
        XCTAssertThrowsError(try conn.query("CREATE (:UniqueMulti {id:3, email:'a@test.com', username:'user_c'})")) { error in
            XCTAssertTrue("\(error)".contains("Unique constraint violation"))
        }
        // Duplicate username should fail
        XCTAssertThrowsError(try conn.query("CREATE (:UniqueMulti {id:4, email:'c@test.com', username:'user_a'})")) { error in
            XCTAssertTrue("\(error)".contains("Unique constraint violation"))
        }
        try conn.dropUniqueIndex(table: "UniqueMulti", property: "email")
        try conn.dropUniqueIndex(table: "UniqueMulti", property: "username")
    }

    func testUniqueIndexIfNotExists() throws {
        let memDb = try Database(":memory:")
        let conn = try Connection(memDb)
        _ = try conn.query("CREATE NODE TABLE UniqueIfNot(id INT64, email STRING, PRIMARY KEY(id))")
        let created = try conn.createUniqueIndexIfNotExists(table: "UniqueIfNot", property: "email")
        XCTAssertTrue(created)
        let notCreated = try conn.createUniqueIndexIfNotExists(table: "UniqueIfNot", property: "email")
        XCTAssertFalse(notCreated)
        try conn.dropUniqueIndex(table: "UniqueIfNot", property: "email")
    }

    // MARK: - Relationship Index Tests

    private func makeRelTestDb() throws -> (Database, Connection) {
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
        _ = try conn.query("CREATE NODE TABLE Account(id INT64, name STRING, PRIMARY KEY(id))")
        _ = try conn.query("CREATE REL TABLE TRANSFER(FROM Account TO Account, amount INT64, label STRING)")
        _ = try conn.query("CREATE (:Account {id: 1, name: 'Alice'})")
        _ = try conn.query("CREATE (:Account {id: 2, name: 'Bob'})")
        _ = try conn.query("CREATE (:Account {id: 3, name: 'Carol'})")
        _ = try conn.query("MATCH (a:Account), (b:Account) WHERE a.id = 1 AND b.id = 2 CREATE (a)-[:TRANSFER {amount: 100, label: 'payment'}]->(b)")
        _ = try conn.query("MATCH (a:Account), (b:Account) WHERE a.id = 2 AND b.id = 3 CREATE (a)-[:TRANSFER {amount: 200, label: 'refund'}]->(b)")
        _ = try conn.query("MATCH (a:Account), (b:Account) WHERE a.id = 1 AND b.id = 3 CREATE (a)-[:TRANSFER {amount: 100, label: 'payment'}]->(b)")
        _ = try conn.query("MATCH (a:Account), (b:Account) WHERE a.id = 3 AND b.id = 1 CREATE (a)-[:TRANSFER {amount: 50, label: 'tip'}]->(b)")
        return (memDb, conn)
    }

    func testRelHashIndexCreateAndLookup() throws {
        let (_, conn) = try makeRelTestDb()
        try conn.createRelHashIndex(table: "TRANSFER", property: "amount")
        // Lookup amount=100 — should find 2 rels
        let results = try conn.queryRelHash(table: "TRANSFER", property: "amount", value: "100")
        XCTAssertEqual(results.count, 2, "Should find 2 rels with amount=100")
        // Lookup amount=200 — should find 1 rel
        let results200 = try conn.queryRelHash(table: "TRANSFER", property: "amount", value: "200")
        XCTAssertEqual(results200.count, 1, "Should find 1 rel with amount=200")
        try conn.dropRelIndex(table: "TRANSFER", property: "amount")
    }

    func testRelRangeIndexCreateAndQuery() throws {
        let (_, conn) = try makeRelTestDb()
        try conn.createRelRangeIndex(table: "TRANSFER", property: "amount")
        // Range 50..100 — should find 3 rels (50, 100, 100)
        let results = try conn.queryRelRange(table: "TRANSFER", property: "amount", min: "50", max: "100")
        XCTAssertEqual(results.count, 3, "Should find 3 rels with amount 50..100")
        try conn.dropRelIndex(table: "TRANSFER", property: "amount")
    }

    func testRelRangeIndexHalfOpen() throws {
        let (_, conn) = try makeRelTestDb()
        try conn.createRelRangeIndex(table: "TRANSFER", property: "amount")
        // amount >= 100
        let results = try conn.queryRelRange(table: "TRANSFER", property: "amount", min: "100")
        XCTAssertEqual(results.count, 3, "Should find 3 rels with amount >= 100")
        // amount <= 100
        let results2 = try conn.queryRelRange(table: "TRANSFER", property: "amount", max: "100")
        XCTAssertEqual(results2.count, 3, "Should find 3 rels with amount <= 100")
        try conn.dropRelIndex(table: "TRANSFER", property: "amount")
    }

    func testRelHashIndexEmptyResult() throws {
        let (_, conn) = try makeRelTestDb()
        try conn.createRelHashIndex(table: "TRANSFER", property: "amount")
        let results = try conn.queryRelHash(table: "TRANSFER", property: "amount", value: "999")
        XCTAssertEqual(results.count, 0, "Should find no rels with amount=999")
        try conn.dropRelIndex(table: "TRANSFER", property: "amount")
    }

    func testRelHashIndexNonUnique() throws {
        let (_, conn) = try makeRelTestDb()
        try conn.createRelHashIndex(table: "TRANSFER", property: "label")
        // 'payment' appears twice
        let results = try conn.queryRelHash(table: "TRANSFER", property: "label", value: "payment")
        XCTAssertEqual(results.count, 2, "Should find 2 rels with label='payment'")
        try conn.dropRelIndex(table: "TRANSFER", property: "label")
    }

    func testRelIndexDrop() throws {
        let (_, conn) = try makeRelTestDb()
        try conn.createRelHashIndex(table: "TRANSFER", property: "amount")
        XCTAssertTrue(try conn.hasRelIndex(table: "TRANSFER", property: "amount"))
        try conn.dropRelIndex(table: "TRANSFER", property: "amount")
        XCTAssertFalse(try conn.hasRelIndex(table: "TRANSFER", property: "amount"))
    }

    func testRelIndexList() throws {
        let (_, conn) = try makeRelTestDb()
        try conn.createRelHashIndex(table: "TRANSFER", property: "amount")
        try conn.createRelRangeIndex(table: "TRANSFER", property: "label")
        let indexes = try conn.listRelIndexes(table: "TRANSFER")
        XCTAssertEqual(indexes.count, 2)
        let names = indexes.map { $0.name }.sorted()
        XCTAssertEqual(names, ["amount", "label"])
        try conn.dropRelIndex(table: "TRANSFER", property: "amount")
        try conn.dropRelIndex(table: "TRANSFER", property: "label")
    }

    func testRelHashIndexEmptyTable() throws {
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
        _ = try conn.query("CREATE NODE TABLE EmptyNode(id INT64, PRIMARY KEY(id))")
        _ = try conn.query("CREATE REL TABLE EMPTY_REL(FROM EmptyNode TO EmptyNode, val INT64)")
        try conn.createRelHashIndex(table: "EMPTY_REL", property: "val")
        let results = try conn.queryRelHash(table: "EMPTY_REL", property: "val", value: "42")
        XCTAssertEqual(results.count, 0, "Empty rel table should return no results")
        try conn.dropRelIndex(table: "EMPTY_REL", property: "val")
    }

    func testRelIndexPersistence() throws {
        let dbPath = NSTemporaryDirectory() + "kuzu_rel_idx_persist_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: true
        )

        // Phase 1: Create table, data, index
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            _ = try conn.query("CREATE NODE TABLE PersistAccount(id INT64, PRIMARY KEY(id))")
            _ = try conn.query("CREATE REL TABLE PERSIST_TRANSFER(FROM PersistAccount TO PersistAccount, amount INT64)")
            _ = try conn.query("CREATE (:PersistAccount {id: 1})")
            _ = try conn.query("CREATE (:PersistAccount {id: 2})")
            _ = try conn.query("MATCH (a:PersistAccount), (b:PersistAccount) WHERE a.id = 1 AND b.id = 2 CREATE (a)-[:PERSIST_TRANSFER {amount: 500}]->(b)")
            try conn.createRelHashIndex(table: "PERSIST_TRANSFER", property: "amount")
            let r = try conn.queryRelHash(table: "PERSIST_TRANSFER", property: "amount", value: "500")
            XCTAssertEqual(r.count, 1, "Should find 1 rel before close")
        }

        // Phase 2: Reopen and verify
        do {
            let diskDb = try Database(dbPath, config)
            let conn = try Connection(diskDb)
            let has = try conn.hasRelIndex(table: "PERSIST_TRANSFER", property: "amount")
            XCTAssertTrue(has, "Rel index should exist after reopen")
            let r = try conn.queryRelHash(table: "PERSIST_TRANSFER", property: "amount", value: "500")
            XCTAssertEqual(r.count, 1, "Should find 1 rel after reopen")
        }
    }

    func testRelIndexMultipleRelTypes() throws {
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
        _ = try conn.query("CREATE NODE TABLE MultiNode(id INT64, PRIMARY KEY(id))")
        _ = try conn.query("CREATE REL TABLE REL_A(FROM MultiNode TO MultiNode, score INT64)")
        _ = try conn.query("CREATE REL TABLE REL_B(FROM MultiNode TO MultiNode, score INT64)")
        _ = try conn.query("CREATE (:MultiNode {id: 1})")
        _ = try conn.query("CREATE (:MultiNode {id: 2})")
        _ = try conn.query("MATCH (a:MultiNode), (b:MultiNode) WHERE a.id = 1 AND b.id = 2 CREATE (a)-[:REL_A {score: 10}]->(b)")
        _ = try conn.query("MATCH (a:MultiNode), (b:MultiNode) WHERE a.id = 1 AND b.id = 2 CREATE (a)-[:REL_B {score: 10}]->(b)")
        // Index on both
        try conn.createRelHashIndex(table: "REL_A", property: "score")
        try conn.createRelHashIndex(table: "REL_B", property: "score")
        let rA = try conn.queryRelHash(table: "REL_A", property: "score", value: "10")
        XCTAssertEqual(rA.count, 1)
        let rB = try conn.queryRelHash(table: "REL_B", property: "score", value: "10")
        XCTAssertEqual(rB.count, 1)
        try conn.dropRelIndex(table: "REL_A", property: "score")
        try conn.dropRelIndex(table: "REL_B", property: "score")
    }

    // MARK: - MERGE ON CREATE SET with Index (Issue #62)

    /// Regression test for GitHub issue #62: MERGE ON CREATE SET fails when a secondary
    /// hash index exists on the property being set. ON CREATE SET is semantically an INSERT,
    /// so the secondary index constraint check should be skipped.
    func testMergeOnCreateSetWithIndex() throws {
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
            "CREATE NODE TABLE MergePerson(id INT64, name STRING, email STRING, PRIMARY KEY(id))"
        )
        _ = try conn.query(
            "CREATE (:MergePerson {id: 1, name: 'Alice', email: 'alice@test.com'})"
        )

        // Create secondary hash index on email
        try conn.createHashIndex(table: "MergePerson", property: "email")

        // MERGE with ON CREATE SET on an indexed property should NOT throw
        _ = try conn.query(
            "MERGE (p:MergePerson {id: 2}) ON CREATE SET p.email = 'bob@test.com', p.name = 'Bob'"
        )

        // Verify the merge created the node
        let result = try conn.query("MATCH (p:MergePerson {id: 2}) RETURN p.email, p.name")
        XCTAssertTrue(result.hasNext())
        let tuple = try result.getNext()!
        let email = try tuple.getValue(0) as! String
        let name = try tuple.getValue(1) as! String
        XCTAssertEqual(email, "bob@test.com")
        XCTAssertEqual(name, "Bob")

        // Verify the index was updated with the new node's email
        let indexResult = try conn.lookupByIndex(
            table: "MergePerson", property: "email", value: "bob@test.com"
        )
        XCTAssertEqual(indexResult.count, 1, "New node should be findable via index")

        // ON MATCH SET on indexed property should also work (updates existing node)
        _ = try conn.query(
            "MERGE (p:MergePerson {id: 1}) ON MATCH SET p.email = 'alice2@test.com'"
        )

        // Verify the update
        let result2 = try conn.query("MATCH (p:MergePerson {id: 1}) RETURN p.email")
        XCTAssertTrue(result2.hasNext())
        let tuple2 = try result2.getNext()!
        let updatedEmail = try tuple2.getValue(0) as! String
        XCTAssertEqual(updatedEmail, "alice2@test.com")

        // Verify index reflects the update
        let oldLookup = try conn.lookupByIndex(
            table: "MergePerson", property: "email", value: "alice@test.com"
        )
        XCTAssertEqual(oldLookup.count, 0, "Old email should not be in index")

        let newLookup = try conn.lookupByIndex(
            table: "MergePerson", property: "email", value: "alice2@test.com"
        )
        XCTAssertEqual(newLookup.count, 1, "Updated email should be in index")

        try conn.dropHashIndex(table: "MergePerson", property: "email")
    }

    func testMergeOnCreateSetWithVectorIndex() throws {
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

        // Create table with embedding column
        _ = try conn.query(
            "CREATE NODE TABLE Image(id STRING, embedding FLOAT[4], PRIMARY KEY(id))"
        )

        // Create HNSW vector index on the embedding column
        _ = try conn.query(
            "CALL CREATE_VECTOR_INDEX('Image', 'emb_idx', 'embedding', metric := 'cosine')"
        )

        // MERGE with ON CREATE SET on the embedding column — should NOT throw
        _ = try conn.query(
            "MERGE (i:Image {id: 'img1'}) ON CREATE SET i.embedding = [0.1, 0.2, 0.3, 0.4]"
        )

        // Verify it was inserted
        let result = try conn.query("MATCH (i:Image {id: 'img1'}) RETURN i.id")
        XCTAssertTrue(result.hasNext())

        // ON MATCH SET on the embedding column — should also work
        _ = try conn.query(
            "MERGE (i:Image {id: 'img1'}) ON MATCH SET i.embedding = [0.5, 0.6, 0.7, 0.8]"
        )
    }

    // MARK: - HNSW Delete/Update Filtering Tests

    func testHNSWDeleteFiltering() throws {
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

        // Create table with 3-dim embedding
        _ = try conn.query(
            "CREATE NODE TABLE Vec(id INT64, embedding FLOAT[3], PRIMARY KEY(id))"
        )

        // Insert 5 nodes with distinct vectors
        _ = try conn.query("CREATE (:Vec {id: 1, embedding: [1.0, 0.0, 0.0]})")
        _ = try conn.query("CREATE (:Vec {id: 2, embedding: [0.0, 1.0, 0.0]})")
        _ = try conn.query("CREATE (:Vec {id: 3, embedding: [0.0, 0.0, 1.0]})")
        _ = try conn.query("CREATE (:Vec {id: 4, embedding: [0.5, 0.5, 0.0]})")
        _ = try conn.query("CREATE (:Vec {id: 5, embedding: [0.0, 0.5, 0.5]})")

        // Create HNSW index
        try conn.createVectorIndex(table: "Vec", indexName: "vec_idx", property: "embedding", metric: "l2")

        // Delete node with id=3
        _ = try conn.query("MATCH (v:Vec {id: 3}) DELETE v")

        // Search for k=5 nearest to [0,0,1] — deleted node (id=3) should NOT appear
        let results = try conn.searchNearest(
            table: "Vec", indexName: "vec_idx", queryVector: [0.0, 0.0, 1.0], k: 5
        )

        // Should get 4 results (not 5, since one was deleted)
        XCTAssertEqual(results.count, 4, "Expected 4 results after deleting 1 of 5 nodes")

        // The deleted node had offset 2 (0-indexed: id=1→offset 0, id=2→offset 1, ..., id=3→offset 2)
        // Verify no result has the deleted node's offset
        let resultOffsets = results.map { $0.nodeID.offset }
        // Verify that we get 4 distinct offsets (the deleted offset should be missing)
        XCTAssertEqual(Set(resultOffsets).count, 4, "Should have 4 distinct offsets")
    }

    func testHNSWUpdateFiltering() throws {
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

        // Create table with 3-dim embedding
        _ = try conn.query(
            "CREATE NODE TABLE Vec2(id INT64, embedding FLOAT[3], PRIMARY KEY(id))"
        )

        // Insert 3 nodes: A=[1,0,0], B=[0,1,0], C=[0,0,1]
        _ = try conn.query("CREATE (:Vec2 {id: 1, embedding: [1.0, 0.0, 0.0]})")
        _ = try conn.query("CREATE (:Vec2 {id: 2, embedding: [0.0, 1.0, 0.0]})")
        _ = try conn.query("CREATE (:Vec2 {id: 3, embedding: [0.0, 0.0, 1.0]})")

        // Create HNSW index
        try conn.createVectorIndex(table: "Vec2", indexName: "vec2_idx", property: "embedding", metric: "l2")

        // Update B's vector to [0.9, 0.0, 0.0] (close to A)
        _ = try conn.query("MATCH (v:Vec2 {id: 2}) SET v.embedding = [0.9, 0.0, 0.0]")

        // Search nearest to [1.0, 0.0, 0.0] with k=3
        let results = try conn.searchNearest(
            table: "Vec2", indexName: "vec2_idx", queryVector: [1.0, 0.0, 0.0], k: 3
        )

        XCTAssertEqual(results.count, 3, "Should still return 3 results after update")

        // Results sorted by distance:
        // id=1 (offset 0) at [1,0,0] → L2 distance 0.0 from query [1,0,0]
        // id=2 (offset 1) updated to [0.9,0,0] → L2 distance ~0.1 from query
        // id=3 (offset 2) at [0,0,1] → L2 distance ~1.41 from query
        XCTAssertTrue(results[0].distance < 0.01, "First result should be exact match")
        XCTAssertTrue(results[1].distance < 0.5, "Second result should be close (updated B)")
        XCTAssertTrue(results[2].distance > 1.0, "Third result should be far (C=[0,0,1])")
    }

    // MARK: - HNSW Bulk Insert with Shrink (Issue #66)

    func testHNSWBulkInsertWithShrink() throws {
        // This test exercises the shrinkForNode code path in HNSW index which calls
        // detachDelete on FWD-only shadow rel tables. Before the fix, this would SIGABRT
        // due to out-of-bounds access in LocalRelTable::delete_.
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

        // Create table with 3-dim embedding
        _ = try conn.query(
            "CREATE NODE TABLE ShrinkTest(id INT64, embedding FLOAT[3], PRIMARY KEY(id))"
        )

        // Insert enough nodes to trigger shrinkForNode with small mu/ml
        for i in 1...30 {
            let x = Float(i) / 30.0
            let y = Float(30 - i) / 30.0
            let z = Float(i % 7) / 7.0
            _ = try conn.query(
                "CREATE (:ShrinkTest {id: \(i), embedding: [\(x), \(y), \(z)]})"
            )
        }

        // Create HNSW index with small mu/ml to trigger shrink earlier
        _ = try conn.query(
            "CALL CREATE_VECTOR_INDEX('ShrinkTest', 'shrink_idx', 'embedding', metric := 'l2', mu := 4, ml := 4)"
        )

        // If we get here without SIGABRT, the fix works.
        // Verify search still returns results.
        let results = try conn.searchNearest(
            table: "ShrinkTest", indexName: "shrink_idx",
            queryVector: [1.0, 0.0, 0.0], k: 5
        )
        XCTAssertEqual(results.count, 5, "Should return 5 nearest neighbors")
        XCTAssertTrue(results[0].distance <= results[1].distance, "Results should be sorted by distance")
    }
}
