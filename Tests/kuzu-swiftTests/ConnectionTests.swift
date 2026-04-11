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
}
