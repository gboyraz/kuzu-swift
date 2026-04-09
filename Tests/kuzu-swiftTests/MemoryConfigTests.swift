//
//  kuzu-swift
//  https://github.com/kuzudb/kuzu-swift
//
//  Copyright © 2023 - 2025 Kùzu Inc.
//  This code is licensed under MIT license (see LICENSE for details)
import Foundation
import XCTest

@testable import Kuzu

final class MemoryConfigTests: XCTestCase {

    // MARK: - SystemConfig Parameter Tests

    func testSystemConfigDefaultInit() throws {
        // Verify that SystemConfig() creates a valid config without crashing
        let config = SystemConfig()
        // Use the config to open an in-memory database to prove it's valid
        let db = try Database(":memory:", config)
        let conn = try Connection(db)
        let result = try conn.query("RETURN 1;")
        XCTAssertTrue(result.hasNext())
    }

    func testSystemConfigWithSmallBufferPool() throws {
        // Test with explicit small buffer pool size (256MB)
        let bufferPoolSize: UInt64 = 256 * 1024 * 1024
        let config = SystemConfig(
            bufferPoolSize: bufferPoolSize,
            maxNumThreads: 1
        )
        let db = try Database(":memory:", config)
        let conn = try Connection(db)
        let result = try conn.query("RETURN 42;")
        XCTAssertTrue(result.hasNext())
        let tuple = try result.getNext()!
        let values = try tuple.getAsArray()
        XCTAssertEqual(values[0] as! Int64, 42)
    }

    func testSystemConfigWithAutoCheckpointDisabled() throws {
        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: false
        )
        let db = try Database(":memory:", config)
        let conn = try Connection(db)
        let result = try conn.query("RETURN 'hello';")
        XCTAssertTrue(result.hasNext())
        let tuple = try result.getNext()!
        let values = try tuple.getAsArray()
        XCTAssertEqual(values[0] as! String, "hello")
    }

    func testSystemConfigCustomValuesOverrideDefaults() throws {
        // Test that custom values are properly applied
        let config = SystemConfig(
            bufferPoolSize: 128 * 1024 * 1024,
            maxNumThreads: 2,
            enableCompression: false,
            readOnly: false,
            autoCheckpoint: false,
            checkpointThreshold: 8 * 1024 * 1024
        )
        // Verify the config works by creating a database and running queries
        let db = try Database(":memory:", config)
        let conn = try Connection(db)
        _ = try conn.query(
            "CREATE NODE TABLE Test(id INT64, name STRING, PRIMARY KEY(id));"
        )
        _ = try conn.query("CREATE (:Test {id: 1, name: 'test'});")
        let result = try conn.query("MATCH (t:Test) RETURN t.id, t.name;")
        XCTAssertTrue(result.hasNext())
        let tuple = try result.getNext()!
        let values = try tuple.getAsArray()
        XCTAssertEqual(values[0] as! Int64, 1)
        XCTAssertEqual(values[1] as! String, "test")
    }

    func testSystemConfigReadOnlyMode() throws {
        let dbPath =
            NSTemporaryDirectory() + "kuzu_swift_test_readonly_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        // First create the database with data
        do {
            let db = try Database(dbPath)
            let conn = try Connection(db)
            _ = try conn.query(
                "CREATE NODE TABLE ReadTest(id INT64, PRIMARY KEY(id));"
            )
            _ = try conn.query("CREATE (:ReadTest {id: 1});")
        }

        // Reopen in read-only mode
        let roConfig = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            readOnly: true
        )
        let db = try Database(dbPath, roConfig)
        let conn = try Connection(db)
        let result = try conn.query("MATCH (r:ReadTest) RETURN r.id;")
        XCTAssertTrue(result.hasNext())
        let tuple = try result.getNext()!
        let values = try tuple.getAsArray()
        XCTAssertEqual(values[0] as! Int64, 1)
    }

    // MARK: - Small Buffer Pool Lifecycle Test

    func testSmallBufferPoolLifecycle() throws {
        let dbPath =
            NSTemporaryDirectory() + "kuzu_swift_test_small_bp_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let smallConfig = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: true
        )

        // Phase 1: Create DB, add schema and data
        do {
            let db = try Database(dbPath, smallConfig)
            let conn = try Connection(db)
            _ = try conn.query(
                "CREATE NODE TABLE Test(id INT64, name STRING, PRIMARY KEY(id));"
            )
            _ = try conn.query("CREATE (:Test {id: 1, name: 'Alice'});")
            _ = try conn.query("CREATE (:Test {id: 2, name: 'Bob'});")
            _ = try conn.query("CREATE (:Test {id: 3, name: 'Charlie'});")
            // Database closes here, should checkpoint
        }

        // Phase 2: Reopen with same small buffer pool, verify data persists
        do {
            let db = try Database(dbPath, smallConfig)
            let conn = try Connection(db)
            let result = try conn.query(
                "MATCH (t:Test) RETURN t.id, t.name ORDER BY t.id;"
            )

            let tuple1 = try result.getNext()!
            let vals1 = try tuple1.getAsArray()
            XCTAssertEqual(vals1[0] as! Int64, 1)
            XCTAssertEqual(vals1[1] as! String, "Alice")

            let tuple2 = try result.getNext()!
            let vals2 = try tuple2.getAsArray()
            XCTAssertEqual(vals2[0] as! Int64, 2)
            XCTAssertEqual(vals2[1] as! String, "Bob")

            let tuple3 = try result.getNext()!
            let vals3 = try tuple3.getAsArray()
            XCTAssertEqual(vals3[0] as! Int64, 3)
            XCTAssertEqual(vals3[1] as! String, "Charlie")

            XCTAssertFalse(result.hasNext())
        }
    }

    // MARK: - Checkpoint Behavior Test

    func testCheckpointBehaviorOnCloseAndReopen() throws {
        let dbPath =
            NSTemporaryDirectory() + "kuzu_swift_test_checkpoint_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: true,
            checkpointThreshold: 1024  // very small threshold to trigger checkpoint
        )

        // Phase 1: Create and populate
        do {
            let db = try Database(dbPath, config)
            let conn = try Connection(db)
            _ = try conn.query(
                "CREATE NODE TABLE CheckpointTest(id INT64, data STRING, PRIMARY KEY(id));"
            )
            for i in 1...10 {
                _ = try conn.query(
                    "CREATE (:CheckpointTest {id: \(i), data: 'row_\(i)'});"
                )
            }
            // DB closes here, checkpoint should occur
        }

        // Phase 2: Reopen and verify all data persists
        do {
            let db = try Database(dbPath, config)
            let conn = try Connection(db)
            let result = try conn.query(
                "MATCH (c:CheckpointTest) RETURN COUNT(c.id);"
            )
            XCTAssertTrue(result.hasNext())
            let tuple = try result.getNext()!
            let values = try tuple.getAsArray()
            XCTAssertEqual(values[0] as! Int64, 10)
        }
    }

    // MARK: - Multiple Close/Reopen Cycles

    func testMultipleCloseReopenCycles() throws {
        let dbPath =
            NSTemporaryDirectory() + "kuzu_swift_test_cycles_" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 1,
            autoCheckpoint: true
        )

        // Cycle 1: Create schema
        do {
            let db = try Database(dbPath, config)
            let conn = try Connection(db)
            _ = try conn.query(
                "CREATE NODE TABLE CycleTest(id INT64, PRIMARY KEY(id));"
            )
        }

        // Cycle 2: Insert data
        do {
            let db = try Database(dbPath, config)
            let conn = try Connection(db)
            _ = try conn.query("CREATE (:CycleTest {id: 1});")
            _ = try conn.query("CREATE (:CycleTest {id: 2});")
        }

        // Cycle 3: Insert more data
        do {
            let db = try Database(dbPath, config)
            let conn = try Connection(db)
            _ = try conn.query("CREATE (:CycleTest {id: 3});")
        }

        // Cycle 4: Verify all data from all cycles
        do {
            let db = try Database(dbPath, config)
            let conn = try Connection(db)
            let result = try conn.query(
                "MATCH (c:CycleTest) RETURN COUNT(c.id);"
            )
            XCTAssertTrue(result.hasNext())
            let tuple = try result.getNext()!
            let values = try tuple.getAsArray()
            XCTAssertEqual(values[0] as! Int64, 3)
        }
    }
}

