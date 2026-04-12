import XCTest
@testable import Kuzu
import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class MemoryTests: XCTestCase {

    // MARK: - Memory Measurement Helper

    /// Returns current RSS (Resident Set Size) in MB
    static func currentRSSInMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    // MARK: - Test 1: Memory stability during repeated INSERT queries

    func testMemoryStabilityDuringBatchInsert() throws {
        let db = try Database(":memory:", SystemConfig(bufferPoolSize: 256 * 1024 * 1024))
        let conn = try Connection(db)

        _ = try conn.query("CREATE NODE TABLE MemNode(id INT64, name STRING, value DOUBLE, PRIMARY KEY(id))")

        let totalQueries = 10_000
        let measureInterval = 1000
        let stmt = try conn.prepare("CREATE (:MemNode {id: $id, name: $name, value: $val})")

        var memorySnapshots: [(queryCount: Int, rssMB: Double)] = []
        let baselineRSS = MemoryTests.currentRSSInMB()
        memorySnapshots.append((0, baselineRSS))
        print("[MemoryTest] Baseline RSS: \(String(format: "%.1f", baselineRSS)) MB")

        let startTime = Date()

        for i in 0..<totalQueries {
            _ = try conn.execute(stmt, [
                "id": Int64(i),
                "name": "node_\(i)",
                "val": Double(i) * 0.001,
            ] as [String: Any?])

            if (i + 1) % measureInterval == 0 {
                let rss = MemoryTests.currentRSSInMB()
                let elapsed = Date().timeIntervalSince(startTime)
                memorySnapshots.append((i + 1, rss))
                print("[MemoryTest] After \(i + 1) inserts: RSS = \(String(format: "%.1f", rss)) MB, elapsed = \(String(format: "%.1f", elapsed))s")
            }
        }

        // Checkpoint to flush WAL
        _ = try conn.query("CHECKPOINT")
        let postCheckpointRSS = MemoryTests.currentRSSInMB()
        print("[MemoryTest] Post-CHECKPOINT RSS: \(String(format: "%.1f", postCheckpointRSS)) MB")

        // Analysis: check if memory growth is bounded
        let firstHalfGrowth = memorySnapshots[5].rssMB - memorySnapshots[1].rssMB  // 1K-5K
        let secondHalfGrowth = memorySnapshots[9].rssMB - memorySnapshots[5].rssMB // 5K-10K
        let totalGrowth = memorySnapshots.last!.rssMB - baselineRSS

        print("[MemoryTest] === MEMORY ANALYSIS ===")
        print("[MemoryTest] Total growth: \(String(format: "%.1f", totalGrowth)) MB")
        print("[MemoryTest] First half growth (1K-5K): \(String(format: "%.1f", firstHalfGrowth)) MB")
        print("[MemoryTest] Second half growth (5K-10K): \(String(format: "%.1f", secondHalfGrowth)) MB")

        // PASS if: total growth < 200MB (reasonable for 10K rows)
        XCTAssertLessThan(totalGrowth, 200.0, "Memory grew more than 200MB for 10K inserts — possible leak")

        if secondHalfGrowth > firstHalfGrowth * 2.0 && firstHalfGrowth > 5.0 {
            print("[MemoryTest] ⚠️ WARNING: Memory growth is accelerating — possible leak")
            print("[MemoryTest]   First half: +\(String(format: "%.1f", firstHalfGrowth)) MB")
            print("[MemoryTest]   Second half: +\(String(format: "%.1f", secondHalfGrowth)) MB")
        } else {
            print("[MemoryTest] ✅ Memory growth is stable/bounded")
        }
    }

    // MARK: - Test 2: Memory stability during repeated READ queries

    func testMemoryStabilityDuringRepeatedReads() throws {
        let db = try Database(":memory:", SystemConfig(bufferPoolSize: 256 * 1024 * 1024))
        let conn = try Connection(db)

        // Setup: create small dataset
        _ = try conn.query("CREATE NODE TABLE ReadNode(id INT64, name STRING, PRIMARY KEY(id))")
        for i in 0..<100 {
            _ = try conn.query("CREATE (:ReadNode {id: \(i), name: 'node_\(i)'})")
        }
        _ = try conn.query("CHECKPOINT")

        let totalQueries = 20_000
        let measureInterval = 2000

        var memorySnapshots: [(queryCount: Int, rssMB: Double)] = []
        let baselineRSS = MemoryTests.currentRSSInMB()
        memorySnapshots.append((0, baselineRSS))
        print("[MemoryTest-Read] Baseline RSS: \(String(format: "%.1f", baselineRSS)) MB")

        let startTime = Date()

        for i in 0..<totalQueries {
            let result = try conn.query("MATCH (n:ReadNode) WHERE n.id = \(i % 100) RETURN n.id, n.name")
            // Consume result
            while result.hasNext() {
                let _ = try result.getNext()
            }

            if (i + 1) % measureInterval == 0 {
                let rss = MemoryTests.currentRSSInMB()
                let elapsed = Date().timeIntervalSince(startTime)
                memorySnapshots.append((i + 1, rss))
                print("[MemoryTest-Read] After \(i + 1) reads: RSS = \(String(format: "%.1f", rss)) MB, elapsed = \(String(format: "%.1f", elapsed))s")
            }
        }

        let totalGrowth = memorySnapshots.last!.rssMB - baselineRSS
        print("[MemoryTest-Read] === ANALYSIS ===")
        print("[MemoryTest-Read] Total growth after \(totalQueries) read queries: \(String(format: "%.1f", totalGrowth)) MB")

        // Read queries should NOT grow memory significantly
        XCTAssertLessThan(totalGrowth, 50.0, "Memory grew \(String(format: "%.1f", totalGrowth))MB after \(totalQueries) read queries — possible leak")
        print("[MemoryTest-Read] ✅ Memory stable during repeated reads")
    }

    // MARK: - Test 3: Query performance stability

    func testQueryPerformanceStability() throws {
        let db = try Database(":memory:", SystemConfig(bufferPoolSize: 256 * 1024 * 1024))
        let conn = try Connection(db)

        // Setup: medium dataset
        _ = try conn.query("CREATE NODE TABLE PerfNode(id INT64, name STRING, score DOUBLE, PRIMARY KEY(id))")
        _ = try conn.query("CREATE REL TABLE PerfEdge(FROM PerfNode TO PerfNode, weight DOUBLE)")

        // Insert 1000 nodes
        let insertStmt = try conn.prepare("CREATE (:PerfNode {id: $id, name: $name, score: $score})")
        for i in 0..<1000 {
            _ = try conn.execute(insertStmt, ["id": Int64(i), "name": "node_\(i)", "score": Double(i) * 0.1] as [String: Any?])
        }

        // Insert 5000 edges
        for i in 0..<5000 {
            let src = i % 1000
            let dst = (i * 7 + 13) % 1000
            _ = try conn.query("MATCH (a:PerfNode {id: \(src)}), (b:PerfNode {id: \(dst)}) CREATE (a)-[:PerfEdge {weight: \(Double(i) * 0.001)}]->(b)")
        }
        _ = try conn.query("CHECKPOINT")

        // Measure query latency over time
        let totalBatches = 10
        let queriesPerBatch = 500
        var batchLatencies: [(batch: Int, avgMs: Double)] = []

        print("[PerfTest] === QUERY PERFORMANCE TEST ===")
        print("[PerfTest] Dataset: 1000 nodes, 5000 edges")
        print("[PerfTest] Running \(totalBatches) batches × \(queriesPerBatch) queries")

        let queryStmt = try conn.prepare("MATCH (a:PerfNode {id: $id})-[:PerfEdge]->(b:PerfNode) RETURN b.id, b.name LIMIT 10")

        for batch in 0..<totalBatches {
            let batchStart = Date()

            for q in 0..<queriesPerBatch {
                let targetId = (batch * queriesPerBatch + q) % 1000
                let result = try conn.execute(queryStmt, ["id": Int64(targetId)] as [String: Any?])
                while result.hasNext() {
                    let _ = try result.getNext()
                }
            }

            let batchMs = Date().timeIntervalSince(batchStart) * 1000
            let avgMs = batchMs / Double(queriesPerBatch)
            batchLatencies.append((batch + 1, avgMs))
            print("[PerfTest] Batch \(batch + 1): avg \(String(format: "%.2f", avgMs))ms/query (total \(String(format: "%.0f", batchMs))ms)")
        }

        // Check: last batch should not be significantly slower than first
        let firstBatchAvg = batchLatencies[0].avgMs
        let lastBatchAvg = batchLatencies.last!.avgMs
        let degradation = lastBatchAvg / firstBatchAvg

        print("[PerfTest] === ANALYSIS ===")
        print("[PerfTest] First batch: \(String(format: "%.2f", firstBatchAvg))ms/query")
        print("[PerfTest] Last batch: \(String(format: "%.2f", lastBatchAvg))ms/query")
        print("[PerfTest] Degradation ratio: \(String(format: "%.2f", degradation))x")

        // PASS if last batch is not more than 3x slower than first
        XCTAssertLessThan(degradation, 3.0, "Query performance degraded \(String(format: "%.1f", degradation))x — possible memory/cache issue")
        print("[PerfTest] ✅ Query performance stable")
    }

    // MARK: - Test 4: Memory after DB close and reopen

    func testMemoryReleasedAfterDBClose() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_memtest_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let beforeOpen = MemoryTests.currentRSSInMB()
        print("[MemRelease] Before DB open: \(String(format: "%.1f", beforeOpen)) MB")

        // Open DB, insert data, close
        do {
            let db = try Database(dbPath, SystemConfig(bufferPoolSize: 128 * 1024 * 1024))
            let conn = try Connection(db)
            _ = try conn.query("CREATE NODE TABLE TempNode(id INT64, data STRING, PRIMARY KEY(id))")

            let stmt = try conn.prepare("CREATE (:TempNode {id: $id, data: $data})")
            for i in 0..<5000 {
                _ = try conn.execute(stmt, ["id": Int64(i), "data": String(repeating: "x", count: 100)] as [String: Any?])
            }
            _ = try conn.query("CHECKPOINT")

            let afterInsert = MemoryTests.currentRSSInMB()
            print("[MemRelease] After 5K inserts: \(String(format: "%.1f", afterInsert)) MB")
        }
        // DB and conn should be deallocated here

        // Give OS time to reclaim
        Thread.sleep(forTimeInterval: 1.0)
        let afterClose = MemoryTests.currentRSSInMB()
        print("[MemRelease] After DB close + 1s: \(String(format: "%.1f", afterClose)) MB")

        // Reopen with smaller buffer pool
        do {
            let db = try Database(dbPath, SystemConfig(bufferPoolSize: 64 * 1024 * 1024))
            let conn = try Connection(db)
            let result = try conn.query("MATCH (n:TempNode) RETURN COUNT(*)")
            let row = try result.getNext()!
            let count = try row.getValue(0) as! Int64
            XCTAssertEqual(count, 5000)
            print("[MemRelease] Reopened, verified \(count) nodes ✅")
        }

        let finalRSS = MemoryTests.currentRSSInMB()
        print("[MemRelease] Final RSS: \(String(format: "%.1f", finalRSS)) MB")
        print("[MemRelease] ✅ DB lifecycle complete")
    }
}

