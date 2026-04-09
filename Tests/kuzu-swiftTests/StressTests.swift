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

    // MARK: - Test 3: Concurrent Queries Under Memory Pressure

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
}

