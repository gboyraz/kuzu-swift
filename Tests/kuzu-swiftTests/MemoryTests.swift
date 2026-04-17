import XCTest
@testable import Kuzu
import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class MemoryTests: XCTestCase {

    // MARK: - Memory Measurement Helpers

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

    /// Returns KuzuDB buffer manager memory usage in MB
    static func kuzuMemoryUsageMB(_ conn: Connection) -> (limitMB: Double, usageMB: Double) {
        do {
            let result = try conn.query("CALL bm_info() RETURN mem_limit, mem_usage")
            if result.hasNext(), let row = try result.getNext() {
                let limit = try row.getValue(0) as! UInt64
                let usage = try row.getValue(1) as! UInt64
                return (Double(limit) / (1024 * 1024), Double(usage) / (1024 * 1024))
            }
        } catch {
            print("[MemoryTest] Warning: Failed to get bm_info: \(error)")
        }
        return (-1, -1)
    }

    struct MemorySnapshot {
        let queryCount: Int
        let processRSSMB: Double
        let kuzuUsageMB: Double
        let kuzuLimitMB: Double

        var nonKuzuMB: Double { processRSSMB - kuzuUsageMB }
    }

    static func captureSnapshot(_ conn: Connection, queryCount: Int) -> MemorySnapshot {
        let rss = currentRSSInMB()
        let (kuzuLimit, kuzuUsage) = kuzuMemoryUsageMB(conn)
        return MemorySnapshot(queryCount: queryCount, processRSSMB: rss, kuzuUsageMB: kuzuUsage, kuzuLimitMB: kuzuLimit)
    }

    static func printSnapshot(_ snapshot: MemorySnapshot, label: String, prefix: String = "[MemoryTest]") {
        print("\(prefix) \(label):")
        print("\(prefix)   Process RSS:     \(String(format: "%.1f", snapshot.processRSSMB)) MB")
        print("\(prefix)   KuzuDB usage:    \(String(format: "%.1f", snapshot.kuzuUsageMB)) MB / \(String(format: "%.1f", snapshot.kuzuLimitMB)) MB limit")
        print("\(prefix)   Non-Kuzu:        \(String(format: "%.1f", snapshot.nonKuzuMB)) MB")
    }

    static func printDualAnalysis(_ first: MemorySnapshot, _ last: MemorySnapshot, prefix: String = "[MemoryTest]") {
        let rssGrowth = last.processRSSMB - first.processRSSMB
        let kuzuGrowth = last.kuzuUsageMB - first.kuzuUsageMB
        let nonKuzuGrowth = last.nonKuzuMB - first.nonKuzuMB
        print("\(prefix) === MEMORY ANALYSIS ===")
        print("\(prefix) Process RSS growth:  \(String(format: "%+.1f", rssGrowth)) MB (\(String(format: "%.1f", first.processRSSMB)) → \(String(format: "%.1f", last.processRSSMB)))")
        print("\(prefix) KuzuDB usage growth: \(String(format: "%+.1f", kuzuGrowth)) MB (\(String(format: "%.1f", first.kuzuUsageMB)) → \(String(format: "%.1f", last.kuzuUsageMB)))")
        print("\(prefix) Non-Kuzu growth:     \(String(format: "%+.1f", nonKuzuGrowth)) MB (\(String(format: "%.1f", first.nonKuzuMB)) → \(String(format: "%.1f", last.nonKuzuMB)))")
        print("\(prefix) KuzuDB buffer pool utilization: \(String(format: "%.1f", last.kuzuUsageMB / last.kuzuLimitMB * 100))% (\(String(format: "%.1f", last.kuzuUsageMB)) / \(String(format: "%.1f", last.kuzuLimitMB)) MB)")
    }

    static func printPerfSummary(totalQueries: Int, totalTime: Double, qpsValues: [Double], prefix: String = "[MemoryTest]") {
        print("\(prefix) === PERFORMANCE SUMMARY ===")
        print("\(prefix) Total queries: \(totalQueries)")
        print("\(prefix) Total time: \(String(format: "%.1f", totalTime))s")
        print("\(prefix) Average QPS: \(String(format: "%.0f", Double(totalQueries) / totalTime))")
        print("\(prefix) Peak QPS: \(String(format: "%.0f", qpsValues.max() ?? 0))")
        print("\(prefix) Min QPS: \(String(format: "%.0f", qpsValues.min() ?? 0))")
    }

    // MARK: - Test 1: Memory stability during repeated INSERT queries

    func testMemoryStabilityDuringBatchInsert() throws {
        let db = try Database(":memory:", SystemConfig(bufferPoolSize: 256 * 1024 * 1024))
        let conn = try Connection(db)

        _ = try conn.query("CREATE NODE TABLE MemNode(id INT64, name STRING, value DOUBLE, PRIMARY KEY(id))")

        let totalQueries = 1_000_000
        let measureInterval = 100_000
        let stmt = try conn.prepare("CREATE (:MemNode {id: $id, name: $name, value: $val})")

        var snapshots: [MemorySnapshot] = []
        let baseline = MemoryTests.captureSnapshot(conn, queryCount: 0)
        snapshots.append(baseline)
        MemoryTests.printSnapshot(baseline, label: "Baseline")

        let startTime = Date()
        var lastIntervalTime = startTime
        var qpsValues: [Double] = []

        for i in 0..<totalQueries {
            _ = try conn.execute(stmt, [
                "id": Int64(i),
                "name": "node_\(i)",
                "val": Double(i) * 0.001,
            ] as [String: Any?])

            if (i + 1) % measureInterval == 0 {
                let now = Date()
                let elapsed = now.timeIntervalSince(startTime)
                let intervalTime = now.timeIntervalSince(lastIntervalTime)
                let intervalQPS = Double(measureInterval) / intervalTime
                let avgQPS = Double(i + 1) / elapsed
                qpsValues.append(intervalQPS)
                lastIntervalTime = now

                let snapshot = MemoryTests.captureSnapshot(conn, queryCount: i + 1)
                snapshots.append(snapshot)
                MemoryTests.printSnapshot(snapshot, label: "After \(i + 1) inserts")
                print("[MemoryTest]   QPS:             \(String(format: "%.0f", intervalQPS)) queries/sec (last interval)")
                print("[MemoryTest]   Avg QPS:         \(String(format: "%.0f", avgQPS)) queries/sec (cumulative)")
            }
        }

        // Checkpoint to flush WAL
        _ = try conn.query("CHECKPOINT")
        let postCheckpoint = MemoryTests.captureSnapshot(conn, queryCount: totalQueries)
        MemoryTests.printSnapshot(postCheckpoint, label: "Post-CHECKPOINT")

        // Analysis
        let totalGrowth = snapshots.last!.processRSSMB - baseline.processRSSMB
        let halfIdx = snapshots.count / 2
        let firstHalfGrowth = snapshots[halfIdx].processRSSMB - snapshots[1].processRSSMB
        let secondHalfGrowth = snapshots.last!.processRSSMB - snapshots[halfIdx].processRSSMB

        MemoryTests.printDualAnalysis(baseline, snapshots.last!)
        MemoryTests.printPerfSummary(totalQueries: totalQueries, totalTime: Date().timeIntervalSince(startTime), qpsValues: qpsValues)

        // PASS if: total growth < 500MB (reasonable for 1M rows)
        XCTAssertLessThan(totalGrowth, 500.0, "Memory grew more than 500MB for 1M inserts — possible leak")

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

        let totalQueries = 1_000_000
        let measureInterval = 100_000

        var snapshots: [MemorySnapshot] = []
        let baseline = MemoryTests.captureSnapshot(conn, queryCount: 0)
        snapshots.append(baseline)
        MemoryTests.printSnapshot(baseline, label: "Baseline", prefix: "[MemoryTest-Read]")

        let startTime = Date()
        var lastIntervalTime = startTime
        var qpsValues: [Double] = []

        for i in 0..<totalQueries {
            let result = try conn.query("MATCH (n:ReadNode) WHERE n.id = \(i % 100) RETURN n.id, n.name")
            while result.hasNext() {
                let _ = try result.getNext()
            }

            if (i + 1) % measureInterval == 0 {
                let now = Date()
                let elapsed = now.timeIntervalSince(startTime)
                let intervalTime = now.timeIntervalSince(lastIntervalTime)
                let intervalQPS = Double(measureInterval) / intervalTime
                let avgQPS = Double(i + 1) / elapsed
                qpsValues.append(intervalQPS)
                lastIntervalTime = now

                let snapshot = MemoryTests.captureSnapshot(conn, queryCount: i + 1)
                snapshots.append(snapshot)
                MemoryTests.printSnapshot(snapshot, label: "After \(i + 1) reads", prefix: "[MemoryTest-Read]")
                print("[MemoryTest-Read]   QPS:             \(String(format: "%.0f", intervalQPS)) queries/sec (last interval)")
                print("[MemoryTest-Read]   Avg QPS:         \(String(format: "%.0f", avgQPS)) queries/sec (cumulative)")
            }
        }

        let totalGrowth = snapshots.last!.processRSSMB - baseline.processRSSMB
        MemoryTests.printDualAnalysis(baseline, snapshots.last!, prefix: "[MemoryTest-Read]")
        MemoryTests.printPerfSummary(totalQueries: totalQueries, totalTime: Date().timeIntervalSince(startTime), qpsValues: qpsValues, prefix: "[MemoryTest-Read]")

        // Read queries should NOT grow memory significantly
        XCTAssertLessThan(totalGrowth, 100.0, "Memory grew \(String(format: "%.1f", totalGrowth))MB after \(totalQueries) read queries — possible leak")
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

        let baseline = MemoryTests.captureSnapshot(conn, queryCount: 0)
        MemoryTests.printSnapshot(baseline, label: "Baseline", prefix: "[PerfTest]")

        // Measure query latency over time
        let totalBatches = 20
        let queriesPerBatch = 50_000
        let totalQueries = totalBatches * queriesPerBatch
        var batchLatencies: [(batch: Int, avgMs: Double)] = []
        var qpsValues: [Double] = []

        print("[PerfTest] === QUERY PERFORMANCE TEST ===")
        print("[PerfTest] Dataset: 1000 nodes, 5000 edges")
        print("[PerfTest] Running \(totalBatches) batches × \(queriesPerBatch) queries")

        let queryStmt = try conn.prepare("MATCH (a:PerfNode {id: $id})-[:PerfEdge]->(b:PerfNode) RETURN b.id, b.name LIMIT 10")
        let startTime = Date()

        for batch in 0..<totalBatches {
            let batchStart = Date()

            for q in 0..<queriesPerBatch {
                let targetId = (batch * queriesPerBatch + q) % 1000
                let result = try conn.execute(queryStmt, ["id": Int64(targetId)] as [String: Any?])
                while result.hasNext() {
                    let _ = try result.getNext()
                }
            }

            let batchTime = Date().timeIntervalSince(batchStart)
            let batchMs = batchTime * 1000
            let avgMs = batchMs / Double(queriesPerBatch)
            let batchQPS = Double(queriesPerBatch) / batchTime
            batchLatencies.append((batch + 1, avgMs))
            qpsValues.append(batchQPS)

            let cumQPS = Double((batch + 1) * queriesPerBatch) / Date().timeIntervalSince(startTime)

            let snapshot = MemoryTests.captureSnapshot(conn, queryCount: (batch + 1) * queriesPerBatch)
            MemoryTests.printSnapshot(snapshot, label: "Batch \(batch + 1)", prefix: "[PerfTest]")
            print("[PerfTest]   avg \(String(format: "%.2f", avgMs))ms/query")
            print("[PerfTest]   QPS:             \(String(format: "%.0f", batchQPS)) queries/sec (last interval)")
            print("[PerfTest]   Avg QPS:         \(String(format: "%.0f", cumQPS)) queries/sec (cumulative)")
        }

        let lastSnapshot = MemoryTests.captureSnapshot(conn, queryCount: totalQueries)

        // Check: last batch should not be significantly slower than first
        let firstBatchAvg = batchLatencies[0].avgMs
        let lastBatchAvg = batchLatencies.last!.avgMs
        let degradation = lastBatchAvg / firstBatchAvg

        MemoryTests.printDualAnalysis(baseline, lastSnapshot, prefix: "[PerfTest]")
        MemoryTests.printPerfSummary(totalQueries: totalQueries, totalTime: Date().timeIntervalSince(startTime), qpsValues: qpsValues, prefix: "[PerfTest]")

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
            for i in 0..<50_000 {
                _ = try conn.execute(stmt, ["id": Int64(i), "data": String(repeating: "x", count: 100)] as [String: Any?])
            }
            _ = try conn.query("CHECKPOINT")

            let afterSnapshot = MemoryTests.captureSnapshot(conn, queryCount: 50_000)
            MemoryTests.printSnapshot(afterSnapshot, label: "After 50K inserts", prefix: "[MemRelease]")
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
            XCTAssertEqual(count, 50_000)

            let reopenSnapshot = MemoryTests.captureSnapshot(conn, queryCount: 0)
            MemoryTests.printSnapshot(reopenSnapshot, label: "After reopen", prefix: "[MemRelease]")
            print("[MemRelease] Reopened, verified \(count) nodes ✅")
        }

        let finalRSS = MemoryTests.currentRSSInMB()
        print("[MemRelease] Final RSS: \(String(format: "%.1f", finalRSS)) MB")
        print("[MemRelease] ✅ DB lifecycle complete")
    }

    // MARK: - Test 5: Memory growth during embedding insert WITH HNSW index (issue #80)

    /// Reproduces issue #80: unbounded WAL C++ heap growth during embedding inserts.
    ///
    /// **Root cause**: Every `execute` creates WAL entries in the C++ heap (outside the buffer
    /// pool). These are invisible to `bm_info()` and only freed by `CHECKPOINT`. On iOS there is
    /// no page-out so jetsam kills the process before a checkpoint is ever reached.
    ///
    /// This test intentionally has NO checkpoint calls to document the worst-case behaviour.
    /// It is expected to FAIL (that is the regression signal). See
    /// `testMemoryGrowthDuringEmbeddingInsertWithHNSWFixed` for the passing variant.
    func testMemoryGrowthDuringEmbeddingInsertWithHNSW() throws {
        let db = try Database(":memory:", SystemConfig(bufferPoolSize: 256 * 1024 * 1024))
        let conn = try Connection(db)

        let dims = 768
        _ = try conn.query("CREATE NODE TABLE Image(id STRING, embedding FLOAT[\(dims)], PRIMARY KEY(id))")
        _ = try conn.query("CALL CREATE_VECTOR_INDEX('Image', 'emb_idx', 'embedding', metric := 'cosine')")

        let totalInserts = 5000
        let measureInterval = 500

        let stmt = try conn.prepare("""
            MERGE (i:Image {id: $id})
            ON CREATE SET i.embedding = $emb
            ON MATCH SET i.embedding = $emb
        """)

        var snapshots: [MemorySnapshot] = []
        let baseline = MemoryTests.captureSnapshot(conn, queryCount: 0)
        snapshots.append(baseline)
        MemoryTests.printSnapshot(baseline, label: "Baseline", prefix: "[EmbeddingTest]")

        for i in 0..<totalInserts {
            try autoreleasepool {
                let embedding = (0..<dims).map { _ in Float.random(in: -1...1) } as NSArray
                _ = try conn.execute(stmt, [
                    "id": "img_\(i)",
                    "emb": embedding
                ] as [String: Any?])
            }

            if (i + 1) % measureInterval == 0 {
                let snapshot = MemoryTests.captureSnapshot(conn, queryCount: i + 1)
                snapshots.append(snapshot)
                MemoryTests.printSnapshot(snapshot, label: "After \(i + 1) inserts", prefix: "[EmbeddingTest]")
            }
        }

        try conn.checkpoint()
        let postCheckpoint = MemoryTests.captureSnapshot(conn, queryCount: totalInserts)
        MemoryTests.printSnapshot(postCheckpoint, label: "Post-CHECKPOINT", prefix: "[EmbeddingTest]")
        MemoryTests.printDualAnalysis(baseline, snapshots.last!, prefix: "[EmbeddingTest]")

        let totalGrowth = snapshots.last!.processRSSMB - baseline.processRSSMB
        XCTAssertLessThan(totalGrowth, 200.0,
            "Memory grew \(String(format: "%.0f", totalGrowth))MB for 5K embeddings (~15MB raw) — excessive WAL overhead")
    }

    // MARK: - Test 6: HNSW inserts WITH periodic checkpoint (fix for issue #80)

    /// Verifies that periodic `checkpoint()` calls bound WAL memory growth during bulk inserts.
    ///
    /// **Important**: This must use a file-backed database. For `:memory:` databases Kuzu's
    /// CHECKPOINT path is currently a no-op, so periodic `checkpoint()` calls do not reclaim
    /// WAL/version-chain memory.
    ///
    /// **Fix**: Call `conn.checkpoint()` every N inserts so WAL C++ heap objects are flushed and
    /// freed before they accumulate to a fatal size. The peak RSS between checkpoints is
    /// proportional to the checkpoint interval, making memory growth predictable and iOS-safer.
    func testMemoryGrowthDuringEmbeddingInsertWithHNSWFixed() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_memtest_hnsw_fixed_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let db = try Database(dbPath, SystemConfig(
            bufferPoolSize: 256 * 1024 * 1024,
            autoCheckpoint: false,
            checkpointThreshold: UInt64.max
        ))
        let conn = try Connection(db)

        let dims = 768
        _ = try conn.query("CREATE NODE TABLE Image(id STRING, embedding FLOAT[\(dims)], PRIMARY KEY(id))")
        _ = try conn.query("CALL CREATE_VECTOR_INDEX('Image', 'emb_idx', 'embedding', metric := 'cosine')")

        let totalInserts = 5000
        let checkpointInterval = 100   // flush WAL every 100 inserts
        let measureInterval = 500

        let stmt = try conn.prepare("""
            MERGE (i:Image {id: $id})
            ON CREATE SET i.embedding = $emb
            ON MATCH SET i.embedding = $emb
        """)

        var snapshots: [MemorySnapshot] = []
        let baseline = MemoryTests.captureSnapshot(conn, queryCount: 0)
        snapshots.append(baseline)
        MemoryTests.printSnapshot(baseline, label: "Baseline", prefix: "[Fixed]")

        var peakRSS = baseline.processRSSMB

        for i in 0..<totalInserts {
            try autoreleasepool {
                let embedding = (0..<dims).map { _ in Float.random(in: -1...1) } as NSArray
                _ = try conn.execute(stmt, [
                    "id": "img_\(i)",
                    "emb": embedding
                ] as [String: Any?])
            }

            // Periodic WAL flush — this is the fix
            if (i + 1) % checkpointInterval == 0 {
                try conn.checkpoint()
            }

            if (i + 1) % measureInterval == 0 {
                let snapshot = MemoryTests.captureSnapshot(conn, queryCount: i + 1)
                snapshots.append(snapshot)
                peakRSS = max(peakRSS, snapshot.processRSSMB)
                MemoryTests.printSnapshot(snapshot, label: "After \(i + 1) inserts", prefix: "[Fixed]")
            }
        }

        try conn.checkpoint()
        let postCheckpoint = MemoryTests.captureSnapshot(conn, queryCount: totalInserts)
        MemoryTests.printSnapshot(postCheckpoint, label: "Post-final-CHECKPOINT", prefix: "[Fixed]")
        MemoryTests.printDualAnalysis(baseline, snapshots.last!, prefix: "[Fixed]")

        print("[Fixed] Peak RSS observed: \(String(format: "%.1f", peakRSS)) MB")

        // For file-backed DBs, periodic checkpoints should keep peak RSS substantially below the
        // original ~400MB+ behavior seen with in-memory accumulation.
        XCTAssertLessThan(peakRSS, 300.0,
            "Peak RSS \(String(format: "%.0f", peakRSS))MB exceeded limit — checkpoint interval may need reducing")
    }

    // MARK: - Test 7: Embedding insert WITHOUT HNSW index (control for issue #80)

    func testMemoryGrowthDuringEmbeddingInsertWithoutHNSW() throws {
        let db = try Database(":memory:", SystemConfig(bufferPoolSize: 256 * 1024 * 1024))
        let conn = try Connection(db)

        let dims = 768
        _ = try conn.query("CREATE NODE TABLE Image(id STRING, embedding FLOAT[\(dims)], PRIMARY KEY(id))")
        // NO HNSW index

        let totalInserts = 5000
        let checkpointInterval = 200
        let measureInterval = 500

        let stmt = try conn.prepare("""
            MERGE (i:Image {id: $id})
            ON CREATE SET i.embedding = $emb
            ON MATCH SET i.embedding = $emb
        """)

        var snapshots: [MemorySnapshot] = []
        let baseline = MemoryTests.captureSnapshot(conn, queryCount: 0)
        snapshots.append(baseline)

        for i in 0..<totalInserts {
            try autoreleasepool {
                let embedding = (0..<dims).map { _ in Float.random(in: -1...1) } as NSArray
                _ = try conn.execute(stmt, [
                    "id": "img_\(i)",
                    "emb": embedding
                ] as [String: Any?])
            }

            if (i + 1) % checkpointInterval == 0 {
                try conn.checkpoint()
            }

            if (i + 1) % measureInterval == 0 {
                let snapshot = MemoryTests.captureSnapshot(conn, queryCount: i + 1)
                snapshots.append(snapshot)
                MemoryTests.printSnapshot(snapshot, label: "After \(i + 1) inserts", prefix: "[NoHNSW]")
            }
        }

        try conn.checkpoint()
        MemoryTests.printDualAnalysis(baseline, snapshots.last!, prefix: "[NoHNSW]")

        let totalGrowth = snapshots.last!.processRSSMB - baseline.processRSSMB
        // ~200 MB growth is expected for 5000 FLOAT[768] inserts into :memory: DB:
        //  - KuzuDB MVCC version chains accumulate (~15 MB tracked, ~180 MB untracked C++ heap)
        //  - CHECKPOINT is a no-op for :memory: databases, so version chains are never cleaned up
        // With our optimizations (move-bind, bulk float array, execute move semantics),
        // growth dropped from ~435 MB to ~200 MB — a ~55% improvement.
        XCTAssertLessThan(totalGrowth, 300.0,
            "Memory grew \(String(format: "%.0f", totalGrowth))MB without HNSW — exceeds expected budget")
    }

    // MARK: - Test 8: HNSW + checkpointAfterNTransactions regression test (issue #80)
    //
    // Verifies that setting `checkpointAfterNTransactions` bounds peak RSS during HNSW
    // bulk insert — the fix for issue #80. With this knob unset, peak RSS for this
    // workload (3400 × FLOAT[768] MERGEs at iOS production config) climbs past 460 MB
    // because `autoCheckpoint` only triggers on WAL file size and WAL grows ~22× slower
    // than in-memory MVCC state for HNSW workloads (WAL ~9 KB/insert vs heap ~200 KB/insert).
    // With `checkpointAfterNTransactions: 500` peak RSS stays under 180 MB — an empirical
    // lower bound chosen with margin over the observed ~120 MB peak on macOS release.
    func testCheckpointAfterNTransactionsBoundsPeakRSS() throws {
        let tempDir = NSTemporaryDirectory() + "kuzu_issue80_" + UUID().uuidString
        let dbPath = tempDir + "/db"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let db = try Database(dbPath, SystemConfig(
            bufferPoolSize: 512 * 1024 * 1024,
            autoCheckpoint: true,
            checkpointThreshold: 64 * 1024 * 1024,
            checkpointAfterNTransactions: 500
        ))
        let conn = try Connection(db)

        let dims = 768
        _ = try conn.query("CREATE NODE TABLE Image(id STRING, embedding FLOAT[\(dims)], PRIMARY KEY(id))")
        _ = try conn.query("CALL CREATE_VECTOR_INDEX('Image', 'emb_idx', 'embedding', metric := 'cosine')")

        let totalInserts = 3400
        let measureInterval = 400

        let stmt = try conn.prepare("""
            MERGE (i:Image {id: $id})
            ON CREATE SET i.embedding = $emb
            ON MATCH SET i.embedding = $emb
        """)

        let baseline = MemoryTests.captureSnapshot(conn, queryCount: 0)
        MemoryTests.printSnapshot(baseline, label: "Baseline", prefix: "[Issue80]")

        var peakRSS = baseline.processRSSMB

        for i in 0..<totalInserts {
            try autoreleasepool {
                let embedding = (0..<dims).map { _ in Float.random(in: -1...1) } as NSArray
                _ = try conn.execute(stmt, [
                    "id": "img_\(i)",
                    "emb": embedding
                ] as [String: Any?])
            }

            if (i + 1) % measureInterval == 0 {
                let snapshot = MemoryTests.captureSnapshot(conn, queryCount: i + 1)
                peakRSS = max(peakRSS, snapshot.processRSSMB)
                MemoryTests.printSnapshot(snapshot, label: "After \(i + 1) inserts", prefix: "[Issue80]")
            }
        }

        let finalSnapshot = MemoryTests.captureSnapshot(conn, queryCount: totalInserts)
        peakRSS = max(peakRSS, finalSnapshot.processRSSMB)
        MemoryTests.printDualAnalysis(baseline, finalSnapshot, prefix: "[Issue80]")

        // Assert on RSS GROWTH, not absolute peak. Absolute peak is contaminated by whatever
        // memory previous tests in the same XCTest process left un-released (can be GBs when
        // running the full `swift test` suite). Growth from this test's own baseline is what
        // actually measures the checkpoint trigger's effectiveness.
        let peakGrowth = peakRSS - baseline.processRSSMB
        print("[Issue80] Peak RSS observed: \(String(format: "%.1f", peakRSS)) MB  (growth from baseline: \(String(format: "%+.1f", peakGrowth)) MB)")

        // Observed ~90 MB peak growth on macOS release with checkpointAfterNTransactions: 500.
        // Without the fix the growth is ~420 MB (see PR #82 baseline). 200 MB bound is
        // well inside the gap for stability across runs + CI variance.
        XCTAssertLessThan(peakGrowth, 200.0,
            "Peak RSS growth \(String(format: "%.0f", peakGrowth)) MB exceeds bound — checkpointAfterNTransactions trigger may be regressed")
    }
}

