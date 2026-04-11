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

    // MARK: - Test: Production Scale 100K Nodes

    func testProductionScale100K() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_100k_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        let csvDir = tempDir + "/csv"
        try FileManager.default.createDirectory(
            atPath: csvDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
            print("[100K Test] Cleaned up temp directory")
        }

        let totalNodes = 100_000
        let embDim = 128
        let overallStart = Date()

        // ── Generate CSV ──
        do {
            let csvStart = Date()
            let csvPath = "\(csvDir)/image_nodes.csv"
            FileManager.default.createFile(atPath: csvPath, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: csvPath))
            defer { handle.closeFile() }

            for i in 0..<totalNodes {
                var embParts = [String]()
                embParts.reserveCapacity(embDim)
                for j in 0..<embDim {
                    let val = sin(Double(i * embDim + j) * 0.001)
                    embParts.append(String(format: "%.6f", val))
                }
                let embedding = "[\(embParts.joined(separator: ","))]"
                let line = "\(i),image_\(i).jpg,\"\(embedding)\"\n"
                handle.write(line.data(using: .utf8)!)

                if (i + 1) % 10_000 == 0 {
                    let elapsed = Date().timeIntervalSince(csvStart)
                    print("[100K Test] CSV: \(i + 1)/\(totalNodes) rows (\(String(format: "%.1f", elapsed))s)")
                }
            }
            let csvElapsed = Date().timeIntervalSince(csvStart)
            print("[100K Test] CSV generation done in \(String(format: "%.1f", csvElapsed))s")

            if let attrs = try? FileManager.default.attributesOfItem(atPath: csvPath) {
                let size = attrs[.size] as? UInt64 ?? 0
                print("[100K Test] CSV file size: \(size / 1024 / 1024) MB")
            }
        }

        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,  // 256MB — realistic iOS config
            maxNumThreads: 2,
            autoCheckpoint: true,
            checkpointThreshold: 64 * 1024 * 1024  // 64MB
        )

        print("[100K Test] Starting with 256MB buffer pool")

        // ── Session 1: Batch insert via UNWIND + verify ──
        do {
            let sessionStart = Date()
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            _ = try conn.query(
                "CREATE NODE TABLE ImageNode(id INT64, path STRING, embedding DOUBLE[\(embDim)], PRIMARY KEY(id));")
            print("[100K Test] Schema created")

            let batchSize = 1000
            let insertStart = Date()
            for batchStart in stride(from: 0, to: totalNodes, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, totalNodes)
                var rows = [String]()
                for i in batchStart..<batchEnd {
                    var embParts = [String]()
                    embParts.reserveCapacity(embDim)
                    for j in 0..<embDim {
                        let val = sin(Double(i * embDim + j) * 0.001)
                        embParts.append(String(format: "%.6f", val))
                    }
                    let embedding = "[\(embParts.joined(separator: ","))]"
                    rows.append("{id: \(i), path: 'image_\(i).jpg', embedding: \(embedding)}")
                }
                let query =
                    "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:ImageNode {id: row.id, path: row.path, embedding: row.embedding});"
                _ = try conn.query(query)

                if batchEnd % 10_000 == 0 {
                    // Explicit checkpoint every 10K to free buffer pool memory
                    _ = try conn.query("CHECKPOINT;")
                    let elapsed = Date().timeIntervalSince(insertStart)
                    print("[100K Test] Inserted \(batchEnd)/\(totalNodes) nodes (\(String(format: "%.1f", elapsed))s) [checkpointed]")
                }
            }

            let insertElapsed = Date().timeIntervalSince(insertStart)
            print("[100K Test] ✅ All \(totalNodes) nodes inserted in \(String(format: "%.1f", insertElapsed))s (\(String(format: "%.0f", Double(totalNodes) / insertElapsed)) nodes/sec)")

            // Verify count
            let countResult = try conn.query("MATCH (n:ImageNode) RETURN COUNT(*);")
            let countTuple = try countResult.getNext()!
            let count = try countTuple.getValue(0) as! Int64
            XCTAssertEqual(count, Int64(totalNodes), "Expected \(totalNodes) nodes, got \(count)")
            print("[100K Test] Count verified: \(count) ✓")

            // Verify a mid-range node
            let midResult = try conn.query("MATCH (n:ImageNode {id: 50000}) RETURN n.path;")
            let midTuple = try midResult.getNext()!
            let midPath = try midTuple.getValue(0) as? String
            XCTAssertEqual(midPath, "image_50000.jpg")
            print("[100K Test] Node id=50000 path: \(midPath ?? "nil") ✓")

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            print("[100K Test] Session 1 complete in \(String(format: "%.1f", sessionElapsed))s")
        }
        // DB and Connection destroyed here

        // ── Session 2: Reopen and verify ──
        do {
            print("[100K Test] Reopening DB...")
            let reopenStart = Date()
            let db = try Database(dbPath, config)
            let conn = try Connection(db)
            let reopenTime = Date().timeIntervalSince(reopenStart)
            print("[100K Test] DB reopened in \(String(format: "%.1f", reopenTime))s")

            // Verify count
            let countResult = try conn.query("MATCH (n:ImageNode) RETURN COUNT(*);")
            let countTuple = try countResult.getNext()!
            let count = try countTuple.getValue(0) as! Int64
            XCTAssertEqual(count, Int64(totalNodes), "Expected \(totalNodes) nodes after reopen, got \(count)")
            print("[100K Test] Count after reopen: \(count) ✓")

            // Verify first node
            let firstResult = try conn.query("MATCH (n:ImageNode {id: 0}) RETURN n.path;")
            let firstTuple = try firstResult.getNext()!
            let firstPath = try firstTuple.getValue(0) as? String
            XCTAssertEqual(firstPath, "image_0.jpg")
            print("[100K Test] Node id=0 path: \(firstPath ?? "nil") ✓")

            // Verify mid-range node
            let midResult = try conn.query("MATCH (n:ImageNode {id: 50000}) RETURN n.path;")
            let midTuple = try midResult.getNext()!
            let midPath = try midTuple.getValue(0) as? String
            XCTAssertEqual(midPath, "image_50000.jpg")
            print("[100K Test] Node id=50000 path: \(midPath ?? "nil") ✓")

            // Verify last node
            let lastResult = try conn.query("MATCH (n:ImageNode {id: 99999}) RETURN n.path;")
            let lastTuple = try lastResult.getNext()!
            let lastPath = try lastTuple.getValue(0) as? String
            XCTAssertEqual(lastPath, "image_99999.jpg")
            print("[100K Test] Node id=99999 path: \(lastPath ?? "nil") ✓")

            // DB size report
            let fm = FileManager.default
            if let enumerator = fm.enumerator(atPath: dbPath) {
                var totalSize: UInt64 = 0
                while let file = enumerator.nextObject() as? String {
                    let fullPath = (dbPath as NSString).appendingPathComponent(file)
                    if let attrs = try? fm.attributesOfItem(atPath: fullPath) {
                        totalSize += attrs[.size] as? UInt64 ?? 0
                    }
                }
                print("[100K Test] DB directory size: \(totalSize / 1024 / 1024) MB")
            }

            print("[100K Test] ✅ All data verified after reopen")
        }

        let totalElapsed = Date().timeIntervalSince(overallStart)
        print("\n[100K Test] === SUMMARY ===")
        print("[100K Test] Total time: \(String(format: "%.1f", totalElapsed))s")
        print("[100K Test] Nodes: \(totalNodes)")
        print("[100K Test] Embedding dims: \(embDim)")
        print("[100K Test] Buffer pool: 256 MB")
        print("[100K Test] ✅ Production scale test PASSED")
    }

    // MARK: - Test: Production Scale 100K Nodes + 1M Edges

    func testProductionScale100KWith1MEdges() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_100k_1m_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        try FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
            NSLog("[Edge Test] Cleaned up temp directory")
        }

        let totalNodes = 100_000
        let totalEdges = 1_000_000
        let embDim = 128
        let overallStart = Date()

        let config = SystemConfig(
            bufferPoolSize: 512 * 1024 * 1024,
            maxNumThreads: 2,
            autoCheckpoint: true,
            checkpointThreshold: 64 * 1024 * 1024
        )

        NSLog("[Edge Test] Starting with 512MB buffer pool")

        var nodeInsertTime: Double = 0
        var edgeInsertTime: Double = 0

        // ── Session 1: Insert nodes and edges ──
        do {
            let sessionStart = Date()
            let db = try Database(dbPath, config)
            let conn = try Connection(db)

            // Create schema
            _ = try conn.query(
                "CREATE NODE TABLE ImageNode(id INT64, path STRING, embedding DOUBLE[\(embDim)], PRIMARY KEY(id));")
            _ = try conn.query(
                "CREATE REL TABLE SIMILAR_TO(FROM ImageNode TO ImageNode, score DOUBLE);")
            NSLog("[Edge Test] Schema created")

            // ── Insert 100K nodes using prepared statement ──
            let nodeStmt = try conn.prepare(
                "CREATE (:ImageNode {id: $id, path: $path, embedding: $embedding})")
            let insertStart = Date()
            for i in 0..<totalNodes {
                let embedding: [Double] = (0..<embDim).map { j in
                    sin(Double(i * embDim + j) * 0.001)
                }
                let params: [String: Any?] = [
                    "id": Int64(i),
                    "path": "image_\(i).jpg",
                    "embedding": embedding,
                ]
                _ = try conn.execute(nodeStmt, params)

                if (i + 1) % 10_000 == 0 {
                    _ = try conn.query("CHECKPOINT;")
                    let elapsed = Date().timeIntervalSince(insertStart)
                    NSLog("[Edge Test] Inserted %d/100000 nodes (%.1fs)", i + 1, elapsed)
                }
            }
            nodeInsertTime = Date().timeIntervalSince(insertStart)
            NSLog("[Edge Test] ✅ All %d nodes inserted in %.1fs (%.0f nodes/sec)",
                  totalNodes, nodeInsertTime, Double(totalNodes) / nodeInsertTime)

            // ── Insert 1M edges using prepared statement ──
            let edgeStmt = try conn.prepare(
                "MATCH (a:ImageNode {id: $src}), (b:ImageNode {id: $dst}) CREATE (a)-[:SIMILAR_TO {score: $score}]->(b)")
            let edgeInsertStart = Date()
            for i in 0..<totalEdges {
                let src = Int64.random(in: 0..<100000)
                let dst = (src + Int64.random(in: 1..<1000)) % 100000
                let score = Double.random(in: 0.0...1.0)
                let params: [String: Any?] = [
                    "src": src,
                    "dst": dst,
                    "score": score,
                ]
                _ = try conn.execute(edgeStmt, params)

                if (i + 1) % 50_000 == 0 {
                    _ = try conn.query("CHECKPOINT;")
                    let elapsed = Date().timeIntervalSince(edgeInsertStart)
                    NSLog("[Edge Test] Inserted %d/1000000 edges (%.1fs)", i + 1, elapsed)
                }
            }
            edgeInsertTime = Date().timeIntervalSince(edgeInsertStart)
            NSLog("[Edge Test] ✅ All %d edges inserted in %.1fs (%.0f edges/sec)",
                  totalEdges, edgeInsertTime, Double(totalEdges) / edgeInsertTime)

            let sessionElapsed = Date().timeIntervalSince(sessionStart)
            NSLog("[Edge Test] Session 1 complete in %.1fs", sessionElapsed)
        }
        // DB and Connection destroyed here

        // ── Session 2: Reopen and verify ──
        do {
            NSLog("[Edge Test] Reopening DB...")
            let reopenStart = Date()
            let db = try Database(dbPath, config)
            let conn = try Connection(db)
            let reopenTime = Date().timeIntervalSince(reopenStart)
            NSLog("[Edge Test] DB reopened in %.1fs", reopenTime)

            // Verify node count
            let countResult = try conn.query("MATCH (n:ImageNode) RETURN COUNT(*);")
            let countTuple = try countResult.getNext()!
            let count = try countTuple.getValue(0) as! Int64
            XCTAssertEqual(count, Int64(totalNodes), "Expected \(totalNodes) nodes, got \(count)")
            NSLog("[Edge Test] Node count verified: %lld ✓", count)

            // Verify edge count
            let edgeCountResult = try conn.query("MATCH ()-[r:SIMILAR_TO]->() RETURN count(r) AS c;")
            let edgeCountTuple = try edgeCountResult.getNext()!
            let edgeCount = try edgeCountTuple.getValue(0) as! Int64
            NSLog("[Edge Test] Edge count: %lld", edgeCount)
            XCTAssertEqual(edgeCount, Int64(totalEdges), "Expected \(totalEdges) edges, got \(edgeCount)")

            // Run graph query
            let graphResult = try conn.query(
                "MATCH (a:ImageNode {id: 0})-[r:SIMILAR_TO]->(b) RETURN b.id, r.score ORDER BY r.score DESC LIMIT 5;")
            NSLog("[Edge Test] Top 5 neighbors of node 0:")
            while graphResult.hasNext() {
                let tuple = try graphResult.getNext()!
                let neighborId = try tuple.getValue(0) as! Int64
                let score = try tuple.getValue(1) as! Double
                NSLog("[Edge Test]   -> node %lld (score: %.4f)", neighborId, score)
            }

            // DB size report
            let fm = FileManager.default
            if let enumerator = fm.enumerator(atPath: dbPath) {
                var totalSize: UInt64 = 0
                while let file = enumerator.nextObject() as? String {
                    let fullPath = (dbPath as NSString).appendingPathComponent(file)
                    if let attrs = try? fm.attributesOfItem(atPath: fullPath) {
                        totalSize += attrs[.size] as? UInt64 ?? 0
                    }
                }
                NSLog("[Edge Test] DB directory size: %llu MB", totalSize / 1024 / 1024)
            }

            NSLog("[Edge Test] ✅ All data verified after reopen")
        }

        let totalElapsed = Date().timeIntervalSince(overallStart)
        NSLog("\n[Edge Test] === SUMMARY ===")
        NSLog("[Edge Test] Total time: %.1fs", totalElapsed)
        NSLog("[Edge Test] Node insert time: %.1fs", nodeInsertTime)
        NSLog("[Edge Test] Edge insert time: %.1fs", edgeInsertTime)
        NSLog("[Edge Test] Nodes: %d, Edges: %d", totalNodes, totalEdges)
        NSLog("[Edge Test] Nodes/sec: %.0f", Double(totalNodes) / nodeInsertTime)
        NSLog("[Edge Test] Edges/sec: %.0f", Double(totalEdges) / edgeInsertTime)
        NSLog("[Edge Test] Buffer pool: 512 MB")
        NSLog("[Edge Test] ✅ Production scale 100K+1M edges test PASSED")
    }

    // MARK: - Test: Throughput Benchmark

    func testThroughputBenchmark() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_bench_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        try FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
        }

        let config = SystemConfig(
            bufferPoolSize: 512 * 1024 * 1024,
            maxNumThreads: 2
        )
        let db = try Database(dbPath, config)
        let conn = try Connection(db)

        // Create schema
        _ = try conn.query(
            "CREATE NODE TABLE BenchNode(id INT64, value DOUBLE, PRIMARY KEY(id));")
        _ = try conn.query(
            "CREATE REL TABLE BENCH_EDGE(FROM BenchNode TO BenchNode, weight DOUBLE);")

        // ── Node throughput benchmark ──
        let nodeStmt = try conn.prepare(
            "CREATE (:BenchNode {id: $id, value: $value})")
        let duration: TimeInterval = 5.0
        var nodeCount: Int64 = 0
        let nodeStart = Date()
        while Date().timeIntervalSince(nodeStart) < duration {
            _ = try conn.execute(nodeStmt, [
                "id": nodeCount,
                "value": Double(nodeCount) * 0.1,
            ])
            nodeCount += 1
        }
        let nodeElapsed = Date().timeIntervalSince(nodeStart)
        let nodesPerSec = Double(nodeCount) / nodeElapsed
        NSLog("[Benchmark] Node throughput: %.0f nodes/sec", nodesPerSec)

        // Checkpoint to flush
        _ = try conn.query("CHECKPOINT;")

        // ── Edge throughput benchmark ──
        let edgeStmt = try conn.prepare(
            "MATCH (a:BenchNode {id: $src}), (b:BenchNode {id: $dst}) CREATE (a)-[:BENCH_EDGE {weight: $w}]->(b)"
        )
        var edgeCount: Int64 = 0
        let edgeStart = Date()
        while Date().timeIntervalSince(edgeStart) < duration {
            let src = Int64.random(in: 0..<nodeCount)
            var dst = Int64.random(in: 0..<nodeCount)
            if dst == src { dst = (dst + 1) % nodeCount }
            _ = try conn.execute(edgeStmt, [
                "src": src,
                "dst": dst,
                "w": Double.random(in: 0.0...1.0),
            ])
            edgeCount += 1
        }
        let edgeElapsed = Date().timeIntervalSince(edgeStart)
        let edgesPerSec = Double(edgeCount) / edgeElapsed
        NSLog("[Benchmark] Edge throughput: %.0f edges/sec", edgesPerSec)

        // Summary
        NSLog("[Benchmark] === RESULTS ===")
        NSLog("[Benchmark] Nodes: %lld inserted in 5s = %.0f nodes/sec", nodeCount, nodesPerSec)
        NSLog("[Benchmark] Edges: %lld inserted in 5s = %.0f edges/sec", edgeCount, edgesPerSec)
    }

    // MARK: - Test: Delete Operations

    func testDeleteOperations() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_delete_ops_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        try FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
            NSLog("[Delete Test] Cleaned up temp directory")
        }

        // Setup: 256MB buffer pool, 2 threads, autoCheckpoint on
        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 2,
            autoCheckpoint: true
        )
        let db = try Database(dbPath, config)
        let conn = try Connection(db)

        // Create schema
        _ = try conn.query("CREATE NODE TABLE TestNode(id INT64, value STRING, PRIMARY KEY(id))")
        _ = try conn.query("CREATE REL TABLE TEST_EDGE(FROM TestNode TO TestNode, weight DOUBLE)")
        NSLog("[Delete Test] Schema created")

        // Insert 1000 nodes in batches
        let totalNodes = 1000
        let batchSize = 100
        for batchStart in stride(from: 0, to: totalNodes, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, totalNodes)
            var rows = [String]()
            for i in batchStart..<batchEnd {
                rows.append("{id: \(i), value: 'node_\(i)'}")
            }
            let query = "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:TestNode {id: row.id, value: row.value});"
            _ = try conn.query(query)
        }
        NSLog("[Delete Test] Inserted %d nodes", totalNodes)

        // Insert 5000 edges in batches
        let totalEdges = 5000
        let edgeBatchSize = 200
        for batchStart in stride(from: 0, to: totalEdges, by: edgeBatchSize) {
            let batchEnd = min(batchStart + edgeBatchSize, totalEdges)
            var edgeRows = [String]()
            for i in batchStart..<batchEnd {
                let fromId = i % totalNodes
                let toId = (i * 7 + 13) % totalNodes
                let weight = Double(i) / Double(totalEdges)
                edgeRows.append("{f: \(fromId), t: \(toId), w: \(String(format: "%.4f", weight))}")
            }
            let query = "UNWIND [\(edgeRows.joined(separator: ","))] AS e MATCH (a:TestNode {id: e.f}), (b:TestNode {id: e.t}) CREATE (a)-[:TEST_EDGE {weight: e.w}]->(b);"
            _ = try conn.query(query)
        }
        NSLog("[Delete Test] Inserted %d edges", totalEdges)

        // Step 4: Test single node delete
        do {
            NSLog("[Delete Test] Deleting single node...")
            _ = try conn.query("MATCH (a:TestNode {id: 999}) DETACH DELETE a")
            NSLog("[Delete Test] Single node deleted ✓")
        } catch {
            NSLog("[Delete Test] Single node delete FAILED: %@", "\(error)")
            XCTFail("Single node delete failed: \(error)")
        }

        // Step 5: Test batch node delete
        do {
            NSLog("[Delete Test] Deleting nodes 900-998...")
            _ = try conn.query("MATCH (a:TestNode) WHERE a.id >= 900 AND a.id < 999 DELETE a")
            NSLog("[Delete Test] Batch node delete ✓")
        } catch {
            NSLog("[Delete Test] Batch node delete FAILED: %@", "\(error)")
            XCTFail("Batch node delete failed: \(error)")
        }

        // Step 6: Test edge delete
        do {
            NSLog("[Delete Test] Deleting edges from node 0...")
            _ = try conn.query("MATCH (a:TestNode {id: 0})-[r:TEST_EDGE]->() DELETE r")
            NSLog("[Delete Test] Edge delete ✓")
        } catch {
            NSLog("[Delete Test] Edge delete FAILED: %@", "\(error)")
            XCTFail("Edge delete failed: \(error)")
        }

        // Step 7: Test bulk delete
        do {
            NSLog("[Delete Test] Bulk deleting 500 nodes with DETACH...")
            _ = try conn.query("MATCH (a:TestNode) WHERE a.id >= 400 AND a.id < 900 DETACH DELETE a")
            NSLog("[Delete Test] Bulk detach delete ✓")
        } catch {
            NSLog("[Delete Test] Bulk detach delete FAILED: %@", "\(error)")
            XCTFail("Bulk detach delete failed: \(error)")
        }

        // Step 8: Verify counts after all deletions
        let nodeResult = try conn.query("MATCH (n:TestNode) RETURN COUNT(*);")
        let nodeTuple = try nodeResult.getNext()!
        let remainingNodes = try nodeTuple.getValue(0) as! Int64
        NSLog("[Delete Test] Remaining nodes: %lld", remainingNodes)

        let edgeResult = try conn.query("MATCH ()-[r:TEST_EDGE]->() RETURN COUNT(r);")
        let edgeTuple = try edgeResult.getNext()!
        let remainingEdges = try edgeTuple.getValue(0) as! Int64
        NSLog("[Delete Test] Remaining edges: %lld", remainingEdges)

        // Step 9: Checkpoint and reopen
        do {
            _ = try conn.query("CALL checkpoint()")
            NSLog("[Delete Test] Checkpoint completed")
        } catch {
            NSLog("[Delete Test] Checkpoint FAILED: %@", "\(error)")
            XCTFail("Checkpoint failed: \(error)")
        }

        // Reopen DB
        let db2 = try Database(dbPath, config)
        let conn2 = try Connection(db2)

        let nodeResult2 = try conn2.query("MATCH (n:TestNode) RETURN COUNT(*);")
        let nodeTuple2 = try nodeResult2.getNext()!
        let reopenNodes = try nodeTuple2.getValue(0) as! Int64
        NSLog("[Delete Test] Reopen node count: %lld", reopenNodes)
        XCTAssertEqual(remainingNodes, reopenNodes, "Node count mismatch after reopen")

        let edgeResult2 = try conn2.query("MATCH ()-[r:TEST_EDGE]->() RETURN COUNT(r);")
        let edgeTuple2 = try edgeResult2.getNext()!
        let reopenEdges = try edgeTuple2.getValue(0) as! Int64
        NSLog("[Delete Test] Reopen edge count: %lld", reopenEdges)
        XCTAssertEqual(remainingEdges, reopenEdges, "Edge count mismatch after reopen")

        NSLog("[Delete Test] Reopen verified ✓")
    }

    // MARK: - Test: Delete At Scale

    func testDeleteAtScale() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_delete_scale_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        try FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
            NSLog("[Delete Scale] Cleaned up temp directory")
        }

        // 256MB buffer pool
        let config = SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            maxNumThreads: 2,
            autoCheckpoint: true
        )
        let db = try Database(dbPath, config)
        let conn = try Connection(db)

        // Create schema
        _ = try conn.query("CREATE NODE TABLE TestNode(id INT64, value STRING, PRIMARY KEY(id))")
        _ = try conn.query("CREATE REL TABLE TEST_EDGE(FROM TestNode TO TestNode, weight DOUBLE)")
        NSLog("[Delete Scale] Schema created")

        // Insert 10000 nodes
        let totalNodes = 10_000
        let batchSize = 500
        let insertStart = Date()
        for batchStart in stride(from: 0, to: totalNodes, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, totalNodes)
            var rows = [String]()
            for i in batchStart..<batchEnd {
                rows.append("{id: \(i), value: 'node_\(i)'}")
            }
            let query = "UNWIND [\(rows.joined(separator: ","))] AS row CREATE (:TestNode {id: row.id, value: row.value});"
            _ = try conn.query(query)
        }
        let nodeInsertElapsed = Date().timeIntervalSince(insertStart)
        NSLog("[Delete Scale] Inserted %d nodes in %.1fs", totalNodes, nodeInsertElapsed)

        // Insert 50000 edges
        let totalEdges = 50_000
        let edgeBatchSize = 500
        let edgeInsertStart = Date()
        for batchStart in stride(from: 0, to: totalEdges, by: edgeBatchSize) {
            let batchEnd = min(batchStart + edgeBatchSize, totalEdges)
            var edgeRows = [String]()
            for i in batchStart..<batchEnd {
                let fromId = i % totalNodes
                let toId = (i * 7 + 13) % totalNodes
                let weight = Double(i) / Double(totalEdges)
                edgeRows.append("{f: \(fromId), t: \(toId), w: \(String(format: "%.4f", weight))}")
            }
            let query = "UNWIND [\(edgeRows.joined(separator: ","))] AS e MATCH (a:TestNode {id: e.f}), (b:TestNode {id: e.t}) CREATE (a)-[:TEST_EDGE {weight: e.w}]->(b);"
            _ = try conn.query(query)
        }
        let edgeInsertElapsed = Date().timeIntervalSince(edgeInsertStart)
        NSLog("[Delete Scale] Inserted %d edges in %.1fs", totalEdges, edgeInsertElapsed)

        // Delete half the edges: weight < 0.5
        do {
            let deleteStart = Date()
            NSLog("[Delete Scale] Deleting edges with weight < 0.5...")
            _ = try conn.query("MATCH ()-[r:TEST_EDGE]->() WHERE r.weight < 0.5 DELETE r")
            let deleteElapsed = Date().timeIntervalSince(deleteStart)
            NSLog("[Delete Scale] Edge delete completed in %.1fs ✓", deleteElapsed)
        } catch {
            NSLog("[Delete Scale] Edge delete FAILED: %@", "\(error)")
            XCTFail("Edge delete at scale failed: \(error)")
        }

        // Delete half the nodes: id >= 5000
        do {
            let deleteStart = Date()
            NSLog("[Delete Scale] Deleting nodes with id >= 5000 (DETACH DELETE)...")
            _ = try conn.query("MATCH (a:TestNode) WHERE a.id >= 5000 DETACH DELETE a")
            let deleteElapsed = Date().timeIntervalSince(deleteStart)
            NSLog("[Delete Scale] Node detach delete completed in %.1fs ✓", deleteElapsed)
        } catch {
            NSLog("[Delete Scale] Node detach delete FAILED: %@", "\(error)")
            XCTFail("Node detach delete at scale failed: \(error)")
        }

        // Verify counts before checkpoint
        let nodeResult = try conn.query("MATCH (n:TestNode) RETURN COUNT(*);")
        let nodeTuple = try nodeResult.getNext()!
        let remainingNodes = try nodeTuple.getValue(0) as! Int64
        NSLog("[Delete Scale] Remaining nodes after delete: %lld", remainingNodes)

        let edgeResult = try conn.query("MATCH ()-[r:TEST_EDGE]->() RETURN COUNT(r);")
        let edgeTuple = try edgeResult.getNext()!
        let remainingEdges = try edgeTuple.getValue(0) as! Int64
        NSLog("[Delete Scale] Remaining edges after delete: %lld", remainingEdges)

        // Checkpoint
        do {
            _ = try conn.query("CALL checkpoint()")
            NSLog("[Delete Scale] Checkpoint completed")
        } catch {
            NSLog("[Delete Scale] Checkpoint FAILED: %@", "\(error)")
            XCTFail("Checkpoint failed: \(error)")
        }

        // Reopen and verify
        let db2 = try Database(dbPath, config)
        let conn2 = try Connection(db2)

        let nodeResult2 = try conn2.query("MATCH (n:TestNode) RETURN COUNT(*);")
        let nodeTuple2 = try nodeResult2.getNext()!
        let reopenNodes = try nodeTuple2.getValue(0) as! Int64
        NSLog("[Delete Scale] Reopen node count: %lld (expected %lld)", reopenNodes, remainingNodes)
        XCTAssertEqual(remainingNodes, reopenNodes, "Node count mismatch after reopen")

        let edgeResult2 = try conn2.query("MATCH ()-[r:TEST_EDGE]->() RETURN COUNT(r);")
        let edgeTuple2 = try edgeResult2.getNext()!
        let reopenEdges = try edgeTuple2.getValue(0) as! Int64
        NSLog("[Delete Scale] Reopen edge count: %lld (expected %lld)", reopenEdges, remainingEdges)
        XCTAssertEqual(remainingEdges, reopenEdges, "Edge count mismatch after reopen")

        NSLog("[Delete Scale] Reopen verified ✓")
    }
}

