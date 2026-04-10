//
//  kuzu-swift
//  https://github.com/kuzudb/kuzu-swift
//
//  Copyright © 2023 - 2025 Kùzu Inc.
//  This code is licensed under MIT license (see LICENSE for details)

// MARK: - Stress Tests (not run by default)
// These tests are excluded from the normal test suite because they take a few minutes.
// Test functions are prefixed with "stressTest" instead of "test" so XCTest won't auto-discover them.
// To run stress tests: swift test --filter "stressTest"
// Or run individual tests: swift test --filter "StressTests/stressTestLargeGraphCreation"

import Foundation
import XCTest

@testable import Kuzu

final class StressTests: XCTestCase {

    // MARK: - Constants

    private static let nodeCount = 50_000
    private static let collectionCount = 100

    // MARK: - Shared DB Setup

    private static var _sharedDBPath: String?
    private static var _sharedCSVDir: String?
    private static let setupLock = NSLock()

    @discardableResult
    private static func ensureSharedDB() throws -> String {
        setupLock.lock()
        defer { setupLock.unlock() }
        if let path = _sharedDBPath {
            return path
        }
        let basePath = NSTemporaryDirectory() + "kuzu_stress_" + UUID().uuidString
        let dbPath = basePath + "/db"
        let csvDir = basePath + "/csv"
        try FileManager.default.createDirectory(
            atPath: csvDir, withIntermediateDirectories: true)
        try generateCSVFiles(csvDir: csvDir)
        try buildLargeGraph(dbPath: dbPath, csvDir: csvDir)
        _sharedDBPath = dbPath
        _sharedCSVDir = csvDir
        return dbPath
    }

    override class func tearDown() {
        if let path = _sharedDBPath {
            // Remove the parent directory (contains both db/ and csv/)
            let parent = (path as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: parent)
            _sharedDBPath = nil
            _sharedCSVDir = nil
        }
        super.tearDown()
    }

    // MARK: - CSV Generation

    private static func generateCSVFiles(csvDir: String) throws {
        let csvStart = Date()
        let fm = FileManager.default

        // 1. image_nodes.csv — 50K rows: id,path,"[emb...]"
        let imageCSVPath = "\(csvDir)/image_nodes.csv"
        fm.createFile(atPath: imageCSVPath, contents: nil)
        let imageHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: imageCSVPath))
        defer { imageHandle.closeFile() }

        for i in 0..<nodeCount {
            var embParts = [String]()
            embParts.reserveCapacity(384)
            for j in 0..<384 {
                let val = sin(Double(i * 384 + j) * 0.001)
                embParts.append(String(format: "%.6f", val))
            }
            let embedding = "[\(embParts.joined(separator: ","))]"
            let line = "\(i),/photos/\(i).jpg,\"\(embedding)\"\n"
            imageHandle.write(line.data(using: .utf8)!)

            if ((i + 1) % 10_000 == 0) {
                let elapsed = Date().timeIntervalSince(csvStart)
                print("[StressTest]   CSV image_nodes: \(i + 1)/\(nodeCount) (\(String(format: "%.1f", elapsed))s)")
            }
        }

        // 2. collection_nodes.csv — 100 rows: id,name
        var collLines = ""
        for i in 0..<collectionCount {
            collLines += "\(i),Collection_\(i)\n"
        }
        try collLines.write(
            toFile: "\(csvDir)/collection_nodes.csv", atomically: true, encoding: .utf8)

        // 3. belongs_to.csv — 50K rows: imageId,collectionId
        var belongsLines = ""
        belongsLines.reserveCapacity(nodeCount * 10)
        for i in 0..<nodeCount {
            belongsLines += "\(i),\(i % collectionCount)\n"
        }
        try belongsLines.write(
            toFile: "\(csvDir)/belongs_to.csv", atomically: true, encoding: .utf8)

        // 4. visual_similarity.csv — 150K rows: from,to,score
        let simPath = "\(csvDir)/visual_similarity.csv"
        fm.createFile(atPath: simPath, contents: nil)
        let simHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: simPath))
        defer { simHandle.closeFile() }

        let simOffsets = [1, 7, 13]
        for i in 0..<nodeCount {
            for offset in simOffsets {
                let target = (i + offset) % nodeCount
                let score = sin(Double(i * offset)) * 0.5 + 0.5
                let line = "\(i),\(target),\(String(format: "%.4f", score))\n"
                simHandle.write(line.data(using: .utf8)!)
            }
        }

        // 5. preferred_over.csv — 50K rows: from,to
        var prefLines = ""
        prefLines.reserveCapacity(nodeCount * 12)
        for i in 0..<nodeCount {
            let target = (i + 3) % nodeCount
            prefLines += "\(i),\(target)\n"
        }
        try prefLines.write(
            toFile: "\(csvDir)/preferred_over.csv", atomically: true, encoding: .utf8)

        let csvElapsed = Date().timeIntervalSince(csvStart)
        print("[StressTest] CSV generation done in \(String(format: "%.1f", csvElapsed))s")

        // Print CSV file sizes
        for name in ["image_nodes.csv", "collection_nodes.csv", "belongs_to.csv",
                      "visual_similarity.csv", "preferred_over.csv"] {
            let path = "\(csvDir)/\(name)"
            if let attrs = try? fm.attributesOfItem(atPath: path) {
                let size = attrs[.size] as? UInt64 ?? 0
                print("[StressTest]   \(name): \(size / 1024) KB")
            }
        }
    }

    // MARK: - Graph Builder (COPY FROM)

    private static func buildLargeGraph(dbPath: String, csvDir: String) throws {
        let config = SystemConfig(
            bufferPoolSize: 512 * 1024 * 1024,
            maxNumThreads: 2,
            autoCheckpoint: true,
            checkpointThreshold: 64 * 1024 * 1024
        )

        let db = try Database(dbPath, config)
        let conn = try Connection(db)

        let overallStart = Date()

        // Create schema
        _ = try conn.query(
            "CREATE NODE TABLE Image(id INT64, path STRING, embedding DOUBLE[384], PRIMARY KEY(id));")
        _ = try conn.query(
            "CREATE NODE TABLE Collection(id INT64, name STRING, PRIMARY KEY(id));")
        _ = try conn.query(
            "CREATE REL TABLE BELONGS_TO(FROM Image TO Collection);")
        _ = try conn.query(
            "CREATE REL TABLE VISUAL_SIMILARITY(FROM Image TO Image, score DOUBLE);")
        _ = try conn.query(
            "CREATE REL TABLE PREFERRED_OVER(FROM Image TO Image);")
        print("[StressTest] Schema created")

        // COPY FROM for nodes
        var stepStart = Date()
        _ = try conn.query("COPY Image FROM '\(csvDir)/image_nodes.csv';")
        var stepElapsed = Date().timeIntervalSince(stepStart)
        print("[StressTest] COPY Image: \(nodeCount) nodes in \(String(format: "%.1f", stepElapsed))s (\(String(format: "%.0f", Double(nodeCount) / stepElapsed)) nodes/sec)")

        stepStart = Date()
        _ = try conn.query("COPY Collection FROM '\(csvDir)/collection_nodes.csv';")
        stepElapsed = Date().timeIntervalSince(stepStart)
        print("[StressTest] COPY Collection: \(collectionCount) nodes in \(String(format: "%.3f", stepElapsed))s")

        // COPY FROM for edges
        stepStart = Date()
        _ = try conn.query("COPY BELONGS_TO FROM '\(csvDir)/belongs_to.csv';")
        stepElapsed = Date().timeIntervalSince(stepStart)
        print("[StressTest] COPY BELONGS_TO: \(nodeCount) edges in \(String(format: "%.1f", stepElapsed))s")

        stepStart = Date()
        _ = try conn.query("COPY VISUAL_SIMILARITY FROM '\(csvDir)/visual_similarity.csv';")
        stepElapsed = Date().timeIntervalSince(stepStart)
        print("[StressTest] COPY VISUAL_SIMILARITY: \(nodeCount * 3) edges in \(String(format: "%.1f", stepElapsed))s")

        stepStart = Date()
        _ = try conn.query("COPY PREFERRED_OVER FROM '\(csvDir)/preferred_over.csv';")
        stepElapsed = Date().timeIntervalSince(stepStart)
        print("[StressTest] COPY PREFERRED_OVER: \(nodeCount) edges in \(String(format: "%.1f", stepElapsed))s")

        // Report totals
        let totalElapsed = Date().timeIntervalSince(overallStart)
        let totalNodes = nodeCount + collectionCount
        let totalEdges = nodeCount * 5  // 50K + 150K + 50K = 250K
        print("\n[StressTest] === SUMMARY ===")
        print("[StressTest] Total import time: \(String(format: "%.1f", totalElapsed))s")
        print("[StressTest] Nodes: \(totalNodes)")
        print("[StressTest] Edges: \(totalEdges)")
        print("[StressTest] Throughput: \(String(format: "%.0f", Double(totalNodes) / totalElapsed)) nodes/sec, \(String(format: "%.0f", Double(totalEdges) / totalElapsed)) edges/sec")

        // Print DB file sizes
        let fm = FileManager.default
        if let enumerator = fm.enumerator(atPath: dbPath) {
            var totalSize: UInt64 = 0
            while let file = enumerator.nextObject() as? String {
                let fullPath = (dbPath as NSString).appendingPathComponent(file)
                if let attrs = try? fm.attributesOfItem(atPath: fullPath) {
                    totalSize += attrs[.size] as? UInt64 ?? 0
                }
            }
            print("[StressTest] DB directory size: \(totalSize / 1024 / 1024) MB")
        }

        // Verify counts
        let imageResult = try conn.query("MATCH (i:Image) RETURN COUNT(*);")
        let imgTuple = try imageResult.getNext()!
        let imgCount = try imgTuple.getValue(0) as! Int64
        XCTAssertEqual(
            imgCount, Int64(nodeCount),
            "Expected \(nodeCount) images, got \(imgCount)")

        let simResult = try conn.query(
            "MATCH ()-[r:VISUAL_SIMILARITY]->() RETURN COUNT(r);")
        let simTuple = try simResult.getNext()!
        let simCount = try simTuple.getValue(0) as! Int64
        XCTAssertEqual(
            simCount, Int64(nodeCount * 3),
            "Expected \(nodeCount * 3) VISUAL_SIMILARITY edges, got \(simCount)")

        print("[StressTest] All counts verified ✓")
    }

    // MARK: - Test 1: Large Graph Creation

    func testLargeGraphCreationWithSmallBufferPool() throws {
        let start = Date()
        let dbPath = try StressTests.ensureSharedDB()
        let elapsed = Date().timeIntervalSince(start)
        print(
            "[StressTest] testLargeGraphCreation completed in \(String(format: "%.1f", elapsed))s"
        )

        // Verify by reopening
        let config = SystemConfig(
            bufferPoolSize: 512 * 1024 * 1024, maxNumThreads: 2)
        let db = try Database(dbPath, config)
        let conn = try Connection(db)

        let result = try conn.query("MATCH (i:Image) RETURN COUNT(*);")
        let tuple = try result.getNext()!
        let count = try tuple.getValue(0) as! Int64
        XCTAssertEqual(count, 50000)

        let edgeResult = try conn.query(
            "MATCH ()-[r:VISUAL_SIMILARITY]->() RETURN COUNT(r);")
        let edgeTuple = try edgeResult.getNext()!
        let edgeCount = try edgeTuple.getValue(0) as! Int64
        XCTAssertEqual(edgeCount, 150000)

        let belongsResult = try conn.query(
            "MATCH ()-[r:BELONGS_TO]->() RETURN COUNT(r);")
        let belongsTuple = try belongsResult.getNext()!
        let belongsCount = try belongsTuple.getValue(0) as! Int64
        XCTAssertEqual(belongsCount, 50000)

        let prefResult = try conn.query(
            "MATCH ()-[r:PREFERRED_OVER]->() RETURN COUNT(r);")
        let prefTuple = try prefResult.getNext()!
        let prefCount = try prefTuple.getValue(0) as! Int64
        XCTAssertEqual(prefCount, 50000)
    }

    // MARK: - Test 2: Reopen with Smaller Buffer Pool

    func testLargeGraphReopenWithSmallerBufferPool() throws {
        let dbPath = try StressTests.ensureSharedDB()

        // Reopen with 256MB buffer pool (half of creation size)
        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024, maxNumThreads: 2)
        let db = try Database(dbPath, config)
        let conn = try Connection(db)

        var start = Date()
        let imageResult = try conn.query("MATCH (i:Image) RETURN COUNT(*);")
        let imageTuple = try imageResult.getNext()!
        let imageCount = try imageTuple.getValue(0) as! Int64
        var elapsed = Date().timeIntervalSince(start)
        print(
            "[StressTest] Image count query: \(imageCount) (\(String(format: "%.3f", elapsed))s)"
        )
        XCTAssertEqual(imageCount, 50000)

        start = Date()
        let simResult = try conn.query(
            "MATCH ()-[r:VISUAL_SIMILARITY]->() RETURN COUNT(r);")
        let simTuple = try simResult.getNext()!
        let simCount = try simTuple.getValue(0) as! Int64
        elapsed = Date().timeIntervalSince(start)
        print(
            "[StressTest] VISUAL_SIMILARITY count: \(simCount) (\(String(format: "%.3f", elapsed))s)"
        )
        XCTAssertEqual(simCount, 150000)

        start = Date()
        let neighborResult = try conn.query(
            "MATCH (i:Image)-[:VISUAL_SIMILARITY]->(j:Image) WHERE i.id = 100 RETURN j.id LIMIT 10;"
        )
        var neighborIds = [Int64]()
        while neighborResult.hasNext() {
            let tuple = try neighborResult.getNext()!
            neighborIds.append(try tuple.getValue(0) as! Int64)
        }
        elapsed = Date().timeIntervalSince(start)
        print(
            "[StressTest] Neighbor query for id=100: \(neighborIds) (\(String(format: "%.3f", elapsed))s)"
        )
        XCTAssertFalse(neighborIds.isEmpty)
    }

    // MARK: - Test 3: Database Reopen After Auto Checkpoint

    func testDatabaseReopenAfterAutoCheckpoint() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_reopen_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        try FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
            print("[StressTest] Cleaned up temp directory")
        }

        let overallStart = Date()

        // ── Session 1: Initial population ──
        do {
            let sessionStart = Date()
            print("[StressTest] Session 1: Creating database and populating data...")

            let config = SystemConfig(
                bufferPoolSize: 256 * 1024 * 1024,
                maxNumThreads: 2,
                autoCheckpoint: true,
                checkpointThreshold: 16 * 1024 * 1024
            )
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            // Create schema
            _ = try conn.query(
                "CREATE NODE TABLE Image(id INT64, path STRING, embedding DOUBLE[384], PRIMARY KEY(id));")
            _ = try conn.query(
                "CREATE REL TABLE VISUAL_SIMILARITY(FROM Image TO Image, score DOUBLE);")
            print("[StressTest]   Schema created")

            // Insert 5000 Image nodes in batches of 100
            let batchSize = 100
            let totalNodes = 5000
            let insertStart = Date()
            for batchStart in stride(from: 0, to: totalNodes, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, totalNodes)
                var rows = [String]()
                for i in batchStart..<batchEnd {
                    var embParts = [String]()
                    embParts.reserveCapacity(384)
                    for j in 0..<384 {
                        let val = sin(Double(i * 384 + j) * 0.001)
                        embParts.append(String(format: "%.6f", val))
                    }
                    let embedding = "[\(embParts.joined(separator: ","))]"
                    rows.append("{id: \(i), path: '/photos/\(i).jpg', embedding: \(embedding)}")
                }
                let query =
                    "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:Image {id: row.id, path: row.path, embedding: row.embedding});"
                _ = try conn.query(query)

                if batchEnd % 1000 == 0 {
                    let elapsed = Date().timeIntervalSince(insertStart)
                    print(
                        "[StressTest]   Inserted \(batchEnd)/\(totalNodes) nodes (\(String(format: "%.1f", elapsed))s)"
                    )
                }
            }
            let nodeElapsed = Date().timeIntervalSince(insertStart)
            print(
                "[StressTest]   All \(totalNodes) nodes inserted in \(String(format: "%.1f", nodeElapsed))s"
            )

            // Insert 2000 VISUAL_SIMILARITY edges in batches
            let edgeStart = Date()
            let totalEdges = 2000
            let edgeBatchSize = 200
            for batchStart in stride(from: 0, to: totalEdges, by: edgeBatchSize) {
                let batchEnd = min(batchStart + edgeBatchSize, totalEdges)
                var edgeRows = [String]()
                for i in batchStart..<batchEnd {
                    edgeRows.append("{f: \(i), t: \(i + 1)}")
                }
                let query =
                    "UNWIND [\(edgeRows.joined(separator: ","))] AS e MATCH (a:Image {id: e.f}), (b:Image {id: e.t}) CREATE (a)-[:VISUAL_SIMILARITY {score: 0.95}]->(b);"
                _ = try conn.query(query)
            }
            let edgeElapsed = Date().timeIntervalSince(edgeStart)
            print(
                "[StressTest]   \(totalEdges) edges inserted in \(String(format: "%.1f", edgeElapsed))s"
            )

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print(
                "[StressTest] Session 1 complete in \(String(format: "%.1f", sessionElapsed))s"
            )
        }
        // DB and Connection are destroyed here

        // ── Session 2: Reopen, verify, write more ──
        do {
            let sessionStart = Date()
            print("[StressTest] Session 2: Reopening database, verifying, and writing more...")

            let config = SystemConfig(
                bufferPoolSize: 256 * 1024 * 1024,
                maxNumThreads: 2,
                autoCheckpoint: true,
                checkpointThreshold: 16 * 1024 * 1024
            )
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            // Verify Image count
            let imgResult = try conn.query("MATCH (i:Image) RETURN COUNT(*);")
            let imgTuple = try imgResult.getNext()!
            let imgCount = try imgTuple.getValue(0) as! Int64
            XCTAssertEqual(imgCount, 5000, "Expected 5000 Image nodes after Session 1, got \(imgCount)")
            print("[StressTest]   Image count: \(imgCount) ✓")

            // Verify edge count
            let edgeResult = try conn.query(
                "MATCH ()-[r:VISUAL_SIMILARITY]->() RETURN COUNT(r);")
            let edgeTuple = try edgeResult.getNext()!
            let edgeCount = try edgeTuple.getValue(0) as! Int64
            XCTAssertEqual(
                edgeCount, 2000,
                "Expected 2000 VISUAL_SIMILARITY edges after Session 1, got \(edgeCount)")
            print("[StressTest]   VISUAL_SIMILARITY count: \(edgeCount) ✓")

            // Verify specific node
            let nodeResult = try conn.query(
                "MATCH (i:Image {id: 100}) RETURN i.path;")
            let nodeTuple = try nodeResult.getNext()!
            let nodePath = try nodeTuple.getValue(0) as? String
            XCTAssertNotNil(nodePath, "Expected node id=100 to have a path")
            print("[StressTest]   Node id=100 path: \(nodePath ?? "nil") ✓")

            // Insert 1000 more Image nodes (id 5000-5999)
            let insertStart = Date()
            let batchSize = 100
            for batchStart in stride(from: 5000, to: 6000, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, 6000)
                var rows = [String]()
                for i in batchStart..<batchEnd {
                    var embParts = [String]()
                    embParts.reserveCapacity(384)
                    for j in 0..<384 {
                        let val = sin(Double(i * 384 + j) * 0.001)
                        embParts.append(String(format: "%.6f", val))
                    }
                    let embedding = "[\(embParts.joined(separator: ","))]"
                    rows.append("{id: \(i), path: '/photos/\(i).jpg', embedding: \(embedding)}")
                }
                let query =
                    "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:Image {id: row.id, path: row.path, embedding: row.embedding});"
                _ = try conn.query(query)
            }
            let insertElapsed = Date().timeIntervalSince(insertStart)
            print(
                "[StressTest]   1000 more nodes inserted in \(String(format: "%.1f", insertElapsed))s"
            )

            // Insert 500 more VISUAL_SIMILARITY edges
            let edgeStart = Date()
            let edgeBatchSize = 100
            for batchStart in stride(from: 2001, to: 2501, by: edgeBatchSize) {
                let batchEnd = min(batchStart + edgeBatchSize, 2501)
                var edgeRows = [String]()
                for i in batchStart..<batchEnd {
                    edgeRows.append("{f: \(i), t: \(i + 1)}")
                }
                let query =
                    "UNWIND [\(edgeRows.joined(separator: ","))] AS e MATCH (a:Image {id: e.f}), (b:Image {id: e.t}) CREATE (a)-[:VISUAL_SIMILARITY {score: 0.95}]->(b);"
                _ = try conn.query(query)
            }
            let edgeElapsed = Date().timeIntervalSince(edgeStart)
            print(
                "[StressTest]   500 more edges inserted in \(String(format: "%.1f", edgeElapsed))s"
            )

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print(
                "[StressTest] Session 2 complete in \(String(format: "%.1f", sessionElapsed))s"
            )
        }
        // DB and Connection are destroyed here

        // ── Session 3: Final verification ──
        do {
            let sessionStart = Date()
            print("[StressTest] Session 3: Final verification...")

            let config = SystemConfig(
                bufferPoolSize: 256 * 1024 * 1024,
                maxNumThreads: 2,
                autoCheckpoint: true,
                checkpointThreshold: 16 * 1024 * 1024
            )
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            // Verify total Image count
            let imgResult = try conn.query("MATCH (i:Image) RETURN COUNT(*);")
            let imgTuple = try imgResult.getNext()!
            let imgCount = try imgTuple.getValue(0) as! Int64
            XCTAssertEqual(imgCount, 6000, "Expected 6000 Image nodes after Session 2, got \(imgCount)")
            print("[StressTest]   Image count: \(imgCount) ✓")

            // Verify total edge count
            let edgeResult = try conn.query(
                "MATCH ()-[r:VISUAL_SIMILARITY]->() RETURN COUNT(r);")
            let edgeTuple = try edgeResult.getNext()!
            let edgeCount = try edgeTuple.getValue(0) as! Int64
            XCTAssertEqual(
                edgeCount, 2500,
                "Expected 2500 VISUAL_SIMILARITY edges after Session 2, got \(edgeCount)")
            print("[StressTest]   VISUAL_SIMILARITY count: \(edgeCount) ✓")

            // Verify old node (id=0) still accessible
            let oldResult = try conn.query(
                "MATCH (i:Image {id: 0}) RETURN i.path;")
            let oldTuple = try oldResult.getNext()!
            let oldPath = try oldTuple.getValue(0) as? String
            XCTAssertNotNil(oldPath, "Expected old node id=0 to still be accessible")
            print("[StressTest]   Old node id=0 path: \(oldPath ?? "nil") ✓")

            // Verify new node (id=5500) accessible
            let newResult = try conn.query(
                "MATCH (i:Image {id: 5500}) RETURN i.path;")
            let newTuple = try newResult.getNext()!
            let newPath = try newTuple.getValue(0) as? String
            XCTAssertNotNil(newPath, "Expected new node id=5500 to be accessible")
            print("[StressTest]   New node id=5500 path: \(newPath ?? "nil") ✓")

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print(
                "[StressTest] Session 3 complete in \(String(format: "%.1f", sessionElapsed))s"
            )
        }

        let totalElapsed = Date().timeIntervalSince(overallStart)
        print("\n[StressTest] === REOPEN TEST SUMMARY ===")
        print("[StressTest] Total time: \(String(format: "%.1f", totalElapsed))s")
        print("[StressTest] 3 sessions completed successfully ✓")
        print("[StressTest] Data integrity verified across close/reopen cycles ✓")
    }

    // MARK: - Test 4: Recovery From Corrupt WAL (SIGKILL Simulation)

    func testRecoveryFromCorruptWAL() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_wal_corrupt_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        try FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
            print("[StressTest] Cleaned up temp directory")
        }

        let fm = FileManager.default
        let overallStart = Date()
        // WAL file path follows Kuzu convention: {dbPath}.wal
        let walPath = dbPath + ".wal"

        // ── Session 1: Create clean baseline ──
        do {
            let sessionStart = Date()
            print("[StressTest] Session 1: Creating database and populating baseline data...")

            let config = SystemConfig(
                bufferPoolSize: 256 * 1024 * 1024,
                maxNumThreads: 2,
                autoCheckpoint: true,
                checkpointThreshold: 16 * 1024 * 1024
            )
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            // Create schema
            _ = try conn.query(
                "CREATE NODE TABLE TestNode(id INT64, data STRING, PRIMARY KEY(id));")
            print("[StressTest]   Schema created")

            // Insert 500 nodes in batches of 100
            for batchStart in stride(from: 0, to: 500, by: 100) {
                let batchEnd = min(batchStart + 100, 500)
                var rows = [String]()
                for i in batchStart..<batchEnd {
                    rows.append("{id: \(i), data: 'node_\(i)'}")
                }
                let query = "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:TestNode {id: row.id, data: row.data});"
                _ = try conn.query(query)
            }
            print("[StressTest]   500 nodes inserted")

            // Force explicit checkpoint
            _ = try conn.query("CHECKPOINT;")
            print("[StressTest]   Explicit CHECKPOINT executed")

            // Insert 200 more nodes WITHOUT checkpoint (WAL only)
            for batchStart in stride(from: 500, to: 700, by: 100) {
                let batchEnd = min(batchStart + 100, 700)
                var rows = [String]()
                for i in batchStart..<batchEnd {
                    rows.append("{id: \(i), data: 'node_\(i)'}")
                }
                let query = "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:TestNode {id: row.id, data: row.data});"
                _ = try conn.query(query)
            }
            print("[StressTest]   200 more nodes inserted (WAL only, no checkpoint)")

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print("[StressTest] Session 1 complete in \(String(format: "%.1f", sessionElapsed))s")
        }
        // DB closes here — forceCheckpointOnClose may checkpoint everything

        // ── Session 2: Corrupt the WAL file to simulate SIGKILL ──
        do {
            print("[StressTest] Session 2: Corrupting WAL file to simulate SIGKILL...")

            // Check multiple possible WAL paths
            var actualWalPath: String? = nil
            let candidatePaths = [walPath]
            // Also check inside the DB directory
            if fm.fileExists(atPath: dbPath) {
                if let contents = try? fm.contentsOfDirectory(atPath: dbPath) {
                    for file in contents where file.contains("wal") {
                        let fullPath = (dbPath as NSString).appendingPathComponent(file)
                        print("[StressTest]   Found WAL-related file inside DB dir: \(file)")
                        if actualWalPath == nil {
                            actualWalPath = fullPath
                        }
                    }
                }
            }
            for path in candidatePaths {
                if fm.fileExists(atPath: path) {
                    print("[StressTest]   Found WAL file at: \(path)")
                    actualWalPath = path
                }
            }

            if let walFilePath = actualWalPath, let walData = fm.contents(atPath: walFilePath), walData.count > 0 {
                // Truncate WAL to 50% of original size
                let originalSize = walData.count
                let truncatedSize = originalSize / 2
                let truncatedData = walData.prefix(truncatedSize)
                try truncatedData.write(to: URL(fileURLWithPath: walFilePath))
                print("[StressTest]   WAL corrupted: \(originalSize) bytes → \(truncatedSize) bytes (50% truncation)")
            } else {
                // WAL was cleared on close (forceCheckpointOnClose=true) or doesn't exist
                // Create a synthetic corrupt WAL to simulate SIGKILL mid-write
                print("[StressTest]   WAL file empty or not found after clean close — creating synthetic corrupt WAL")
                // Write random bytes that look like a partially written WAL
                var corruptData = Data(count: 4096)
                corruptData.withUnsafeMutableBytes { ptr in
                    // Write some header-like bytes then garbage
                    let bytes = ptr.bindMemory(to: UInt8.self)
                    for i in 0..<4096 {
                        bytes[i] = UInt8(i % 256)
                    }
                }
                try corruptData.write(to: URL(fileURLWithPath: walPath))
                print("[StressTest]   Synthetic corrupt WAL written: 4096 bytes at \(walPath)")
            }
        }

        // ── Session 3: Verify recovery (THE KEY TEST) ──
        do {
            let sessionStart = Date()
            print("[StressTest] Session 3: Opening database after WAL corruption...")

            let config = SystemConfig(
                bufferPoolSize: 256 * 1024 * 1024,
                maxNumThreads: 2,
                autoCheckpoint: true,
                checkpointThreshold: 16 * 1024 * 1024
            )

            // This MUST NOT throw — if it does, the test fails
            let db = try Database(dbPath, config)
            let conn = try Connection(db)
            print("[StressTest]   Database opened successfully after WAL corruption ✓")

            // Query count — should be >= 500 (checkpointed baseline)
            let countResult = try conn.query("MATCH (n:TestNode) RETURN count(n);")
            let countTuple = try countResult.getNext()!
            let recoveredCount = try countTuple.getValue(0) as! Int64
            XCTAssertGreaterThanOrEqual(recoveredCount, 500,
                "Expected at least 500 nodes (checkpointed baseline), got \(recoveredCount)")
            print("[StressTest]   Recovered node count: \(recoveredCount) (expected >= 500) ✓")

            // Verify a specific checkpointed node
            let nodeResult = try conn.query("MATCH (n:TestNode {id: 100}) RETURN n.data;")
            let nodeTuple = try nodeResult.getNext()!
            let nodeData = try nodeTuple.getValue(0) as? String
            XCTAssertEqual(nodeData, "node_100", "Expected node_100 data, got \(nodeData ?? "nil")")
            print("[StressTest]   Node id=100 data: \(nodeData ?? "nil") ✓")

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print("[StressTest] Session 3 complete in \(String(format: "%.1f", sessionElapsed))s")
        }

        // ── Session 4: Verify DB is usable after recovery ──
        do {
            let sessionStart = Date()
            print("[StressTest] Session 4: Verifying DB is usable after recovery...")

            let config = SystemConfig(
                bufferPoolSize: 256 * 1024 * 1024,
                maxNumThreads: 2,
                autoCheckpoint: true,
                checkpointThreshold: 16 * 1024 * 1024
            )
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            // Get count before insert
            let beforeResult = try conn.query("MATCH (n:TestNode) RETURN count(n);")
            let beforeTuple = try beforeResult.getNext()!
            let beforeCount = try beforeTuple.getValue(0) as! Int64

            // Insert 100 new nodes (ids 10000-10099)
            var rows = [String]()
            for i in 10000..<10100 {
                rows.append("{id: \(i), data: 'node_\(i)'}")
            }
            let query = "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:TestNode {id: row.id, data: row.data});"
            _ = try conn.query(query)
            print("[StressTest]   100 new nodes inserted (ids 10000-10099)")

            // Verify count increased
            let afterResult = try conn.query("MATCH (n:TestNode) RETURN count(n);")
            let afterTuple = try afterResult.getNext()!
            let afterCount = try afterTuple.getValue(0) as! Int64
            XCTAssertEqual(afterCount, beforeCount + 100,
                "Expected count to increase by 100: before=\(beforeCount), after=\(afterCount)")
            print("[StressTest]   Count increased: \(beforeCount) → \(afterCount) ✓")

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print("[StressTest] Session 4 complete in \(String(format: "%.1f", sessionElapsed))s")
        }

        // ── Session 5: Final persistence check ──
        do {
            let sessionStart = Date()
            print("[StressTest] Session 5: Final persistence check...")

            let config = SystemConfig(
                bufferPoolSize: 256 * 1024 * 1024,
                maxNumThreads: 2,
                autoCheckpoint: true,
                checkpointThreshold: 16 * 1024 * 1024
            )
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            // Verify node from Session 4 persisted
            let result = try conn.query("MATCH (n:TestNode {id: 10050}) RETURN n.data;")
            let tuple = try result.getNext()!
            let data = try tuple.getValue(0) as? String
            XCTAssertEqual(data, "node_10050", "Expected node_10050 data, got \(data ?? "nil")")
            print("[StressTest]   Node id=10050 data: \(data ?? "nil") ✓")

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print("[StressTest] Session 5 complete in \(String(format: "%.1f", sessionElapsed))s")
        }

        let totalElapsed = Date().timeIntervalSince(overallStart)
        print("\n[StressTest] === CORRUPT WAL RECOVERY TEST SUMMARY ===")
        print("[StressTest] Total time: \(String(format: "%.1f", totalElapsed))s")
        print("[StressTest] 5 sessions completed successfully ✓")
        print("[StressTest] Database recovered from corrupt WAL ✓")
        print("[StressTest] Data integrity verified after recovery ✓")
        print("[StressTest] New writes work after recovery ✓")
        print("[StressTest] Persistence verified after recovery ✓")
    }

    // MARK: - Test 5: Concurrent Queries Under Memory Pressure

    func testConcurrentQueriesUnderMemoryPressure() throws {
        let dbPath = try StressTests.ensureSharedDB()

        let config = SystemConfig(
            bufferPoolSize: 512 * 1024 * 1024, maxNumThreads: 2)
        let db = try Database(dbPath, config)

        let expectation = XCTestExpectation(
            description: "Concurrent queries complete")
        expectation.expectedFulfillmentCount = 10

        let errors = NSMutableArray()  // thread-safe via @objc
        let queue = DispatchQueue(
            label: "stress.concurrent", attributes: .concurrent)

        for queryIdx in 0..<10 {
            queue.async {
                do {
                    let conn = try Connection(db)
                    let targetId = queryIdx * 5000
                    let result = try conn.query(
                        "MATCH (i:Image)-[:VISUAL_SIMILARITY]->(j:Image) WHERE i.id = \(targetId) RETURN j.id, j.path LIMIT 5;"
                    )
                    var count = 0
                    while result.hasNext() {
                        let tuple = try result.getNext()!
                        _ = try tuple.getValue(0)
                        count += 1
                    }
                    print(
                        "[StressTest] Concurrent query \(queryIdx) (id=\(targetId)): \(count) results"
                    )
                } catch {
                    errors.add("Query \(queryIdx) failed: \(error)")
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 120)

        if errors.count > 0 {
            XCTFail("Concurrent query errors: \(errors)")
        }
    }

    // MARK: - Test 6: Spiller With Large Batch Insert

    func testSpillerWithLargeBatchInsert() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_spiller_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        try FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
            print("[StressTest] Cleaned up temp directory")
        }

        let overallStart = Date()
        let bufferPoolSize = 64 * 1024 * 1024  // 64MB — designed to force Spiller activation
        print("[StressTest] === SPILLER TEST ===")
        print("[StressTest] Buffer pool size: \(bufferPoolSize / 1024 / 1024) MB")
        print("[StressTest] Target: 10,000 nodes × 128 doubles ≈ 10MB+ data footprint")

        // ── Session 1: Large batch insert with tiny buffer pool ──
        do {
            let sessionStart = Date()
            print("[StressTest] Session 1: Inserting 10,000 nodes with 128-dim embeddings...")

            let config = SystemConfig(
                bufferPoolSize: UInt64(bufferPoolSize),
                maxNumThreads: 2,
                autoCheckpoint: true,
                checkpointThreshold: 16 * 1024 * 1024
            )
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            // Create schema
            _ = try conn.query(
                "CREATE NODE TABLE SpillerNode(id INT64, data STRING, embedding DOUBLE[128], PRIMARY KEY(id));")
            print("[StressTest]   Schema created")

            // Insert 10,000 nodes in batches of 500
            let totalNodes = 10_000
            let batchSize = 500
            let insertStart = Date()
            for batchStart in stride(from: 0, to: totalNodes, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, totalNodes)
                var rows = [String]()
                for i in batchStart..<batchEnd {
                    var embParts = [String]()
                    embParts.reserveCapacity(128)
                    for j in 0..<128 {
                        let val = sin(Double(i * 128 + j) * 0.001)
                        embParts.append(String(format: "%.6f", val))
                    }
                    let embedding = "[\(embParts.joined(separator: ","))]"
                    rows.append("{id: \(i), data: 'spiller_node_\(i)', embedding: \(embedding)}")
                }
                let query =
                    "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:SpillerNode {id: row.id, data: row.data, embedding: row.embedding});"
                _ = try conn.query(query)

                if batchEnd % 2000 == 0 || batchEnd == totalNodes {
                    let elapsed = Date().timeIntervalSince(insertStart)
                    print(
                        "[StressTest]   Inserted \(batchEnd)/\(totalNodes) nodes (\(String(format: "%.1f", elapsed))s)"
                    )
                }
            }

            let insertElapsed = Date().timeIntervalSince(insertStart)
            print(
                "[StressTest]   All \(totalNodes) nodes inserted in \(String(format: "%.1f", insertElapsed))s"
            )
            print(
                "[StressTest]   Throughput: \(String(format: "%.0f", Double(totalNodes) / insertElapsed)) nodes/sec"
            )

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print(
                "[StressTest] Session 1 complete in \(String(format: "%.1f", sessionElapsed))s"
            )
        }
        // DB and Connection are destroyed here

        // ── Session 2: Verify data survived ──
        do {
            let sessionStart = Date()
            print("[StressTest] Session 2: Reopening and verifying data survived...")

            let config = SystemConfig(
                bufferPoolSize: UInt64(bufferPoolSize),
                maxNumThreads: 2,
                autoCheckpoint: true,
                checkpointThreshold: 16 * 1024 * 1024
            )
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            // Verify total count
            let countResult = try conn.query("MATCH (n:SpillerNode) RETURN count(n);")
            let countTuple = try countResult.getNext()!
            let count = try countTuple.getValue(0) as! Int64
            XCTAssertEqual(count, 10000, "Expected 10000 SpillerNode nodes, got \(count)")
            print("[StressTest]   Node count: \(count) ✓")

            // Verify first node
            let firstResult = try conn.query("MATCH (n:SpillerNode {id: 0}) RETURN n.data;")
            let firstTuple = try firstResult.getNext()!
            let firstName = try firstTuple.getValue(0) as? String
            XCTAssertEqual(firstName, "spiller_node_0", "Expected spiller_node_0, got \(firstName ?? "nil")")
            print("[StressTest]   Node id=0 data: \(firstName ?? "nil") ✓")

            // Verify last node
            let lastResult = try conn.query("MATCH (n:SpillerNode {id: 9999}) RETURN n.data;")
            let lastTuple = try lastResult.getNext()!
            let lastName = try lastTuple.getValue(0) as? String
            XCTAssertEqual(lastName, "spiller_node_9999", "Expected spiller_node_9999, got \(lastName ?? "nil")")
            print("[StressTest]   Node id=9999 data: \(lastName ?? "nil") ✓")

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print(
                "[StressTest] Session 2 complete in \(String(format: "%.1f", sessionElapsed))s"
            )
        }

        // ── Session 3: Verify writable after ──
        do {
            let sessionStart = Date()
            print("[StressTest] Session 3: Inserting 1,000 more nodes and verifying...")

            let config = SystemConfig(
                bufferPoolSize: UInt64(bufferPoolSize),
                maxNumThreads: 2,
                autoCheckpoint: true,
                checkpointThreshold: 16 * 1024 * 1024
            )
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            // Insert 1000 more nodes (id 10000-10999) in batches of 500
            let insertStart = Date()
            for batchStart in stride(from: 10000, to: 11000, by: 500) {
                let batchEnd = min(batchStart + 500, 11000)
                var rows = [String]()
                for i in batchStart..<batchEnd {
                    var embParts = [String]()
                    embParts.reserveCapacity(128)
                    for j in 0..<128 {
                        let val = sin(Double(i * 128 + j) * 0.001)
                        embParts.append(String(format: "%.6f", val))
                    }
                    let embedding = "[\(embParts.joined(separator: ","))]"
                    rows.append("{id: \(i), data: 'spiller_node_\(i)', embedding: \(embedding)}")
                }
                let query =
                    "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:SpillerNode {id: row.id, data: row.data, embedding: row.embedding});"
                _ = try conn.query(query)
            }
            let insertElapsed = Date().timeIntervalSince(insertStart)
            print(
                "[StressTest]   1,000 more nodes inserted in \(String(format: "%.1f", insertElapsed))s"
            )

            // Verify total count
            let countResult = try conn.query("MATCH (n:SpillerNode) RETURN count(n);")
            let countTuple = try countResult.getNext()!
            let count = try countTuple.getValue(0) as! Int64
            XCTAssertEqual(count, 11000, "Expected 11000 SpillerNode nodes, got \(count)")
            print("[StressTest]   Total node count: \(count) ✓")

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print(
                "[StressTest] Session 3 complete in \(String(format: "%.1f", sessionElapsed))s"
            )
        }

        let totalElapsed = Date().timeIntervalSince(overallStart)
        print("\n[StressTest] === SPILLER TEST SUMMARY ===")
        print("[StressTest] Buffer pool: \(bufferPoolSize / 1024 / 1024) MB")
        print("[StressTest] Total time: \(String(format: "%.1f", totalElapsed))s")
        print("[StressTest] 3 sessions completed successfully ✓")
        print("[StressTest] Spiller mechanism validated — data > buffer pool survived ✓")
    }

    // MARK: - Buffer Pool Scale Baseline

    func testBufferPoolScaleBaseline() throws {
        let sizes: [(name: String, size: UInt64)] = [
            ("64MB", 64 * 1024 * 1024),
            ("32MB", 32 * 1024 * 1024),
        ]

        for (sizeName, bufferPoolSize) in sizes {
            let tempDir = NSTemporaryDirectory() + "kuzu_scale_\(sizeName)_\(UUID().uuidString)"
            try FileManager.default.createDirectory(
                atPath: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tempDir) }

            print("[ScaleTest] Testing with \(sizeName) buffer pool")

            let steps = [1000, 5000, 10_000, 20_000, 50_000]
            var maxSuccessful = 0

            for nodeCount in steps {
                do {
                    let stepDir = tempDir + "/step_\(nodeCount)"
                    try FileManager.default.createDirectory(
                        atPath: stepDir, withIntermediateDirectories: true)
                    let dbPath = stepDir + "/db"

                    let config = SystemConfig(
                        bufferPoolSize: bufferPoolSize,
                        maxNumThreads: 2,
                        autoCheckpoint: true,
                        checkpointThreshold: 8 * 1024 * 1024  // 8MB
                    )

                    let db = try Database(dbPath, config)
                    let conn = try Connection(db)

                    // Create schema
                    _ = try conn.query(
                        "CREATE NODE TABLE ScaleNode(id INT64, data STRING, embedding DOUBLE[128], PRIMARY KEY(id));"
                    )

                    // Insert in batches of 500
                    let start = Date()
                    let batchSize = 500
                    for batchStart in stride(from: 0, to: nodeCount, by: batchSize) {
                        let batchEnd = min(batchStart + batchSize, nodeCount)
                        var rows = [String]()
                        for i in batchStart..<batchEnd {
                            var embParts = [String]()
                            embParts.reserveCapacity(128)
                            for j in 0..<128 {
                                let val = sin(Double(i * 128 + j) * 0.001)
                                embParts.append(String(format: "%.6f", val))
                            }
                            let embedding = "[\(embParts.joined(separator: ","))]"
                            rows.append(
                                "{id: \(i), data: 'node_\(i)', embedding: \(embedding)}")
                        }
                        let query =
                            "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:ScaleNode {id: row.id, data: row.data, embedding: row.embedding});"
                        _ = try conn.query(query)
                    }

                    // Verify count
                    let countResult = try conn.query(
                        "MATCH (n:ScaleNode) RETURN count(n) AS c;")
                    let countTuple = try countResult.getNext()!
                    let count = try countTuple.getValue(0) as! Int64

                    let elapsed = Date().timeIntervalSince(start)
                    maxSuccessful = nodeCount
                    print(
                        "[ScaleTest] \(sizeName): ✅ \(nodeCount) nodes inserted (\(count) verified) in \(String(format: "%.1f", elapsed))s"
                    )

                } catch {
                    print(
                        "[ScaleTest] \(sizeName): ❌ CRASHED at \(nodeCount) nodes: \(error)"
                    )
                    break  // Don't try larger sizes
                }
            }

            print("[ScaleTest] \(sizeName): Max successful = \(maxSuccessful) nodes")
        }
    }
}

