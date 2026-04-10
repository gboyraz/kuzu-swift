#pragma once

#include "storage/wal/wal_record.h"

namespace kuzu {
namespace binder {
struct BoundAlterInfo;
} // namespace binder
namespace common {
class InMemFileWriter;
class ValueVector;
} // namespace common
namespace catalog {
class CatalogEntry;
} // namespace catalog
namespace main {
class ClientContext;
} // namespace main

namespace storage {
class WAL;
class LocalWAL {
    friend class WAL;

public:
    // Default threshold for mid-transaction WAL flush: 32MB.
    static constexpr uint64_t DEFAULT_WAL_FLUSH_THRESHOLD = 32 * 1024 * 1024;

    explicit LocalWAL(MemoryManager& mm);

    // Set the global WAL and client context for mid-transaction flushing.
    // When the in-memory WAL size exceeds the threshold, buffered records are
    // flushed to the global WAL file to bound memory usage.
    void setFlushContext(WAL* globalWAL, main::ClientContext* context,
        uint64_t flushThreshold = DEFAULT_WAL_FLUSH_THRESHOLD);

    void logCreateCatalogEntryRecord(catalog::CatalogEntry* catalogEntry, bool isInternal);
    void logDropCatalogEntryRecord(uint64_t tableID, catalog::CatalogEntryType type);
    void logAlterCatalogEntryRecord(const binder::BoundAlterInfo* alterInfo);
    void logUpdateSequenceRecord(common::sequence_id_t sequenceID, uint64_t kCount);

    void logTableInsertion(common::table_id_t tableID, common::TableType tableType,
        common::row_idx_t numRows, const std::vector<common::ValueVector*>& vectors);
    void logNodeDeletion(common::table_id_t tableID, common::offset_t nodeOffset,
        common::ValueVector* pkVector);
    void logNodeUpdate(common::table_id_t tableID, common::column_id_t columnID,
        common::offset_t nodeOffset, common::ValueVector* propertyVector);
    void logRelDelete(common::table_id_t tableID, common::ValueVector* srcNodeVector,
        common::ValueVector* dstNodeVector, common::ValueVector* relIDVector);
    void logRelDetachDelete(common::table_id_t tableID, common::RelDataDirection direction,
        common::ValueVector* srcNodeVector);
    void logRelUpdate(common::table_id_t tableID, common::column_id_t columnID,
        common::ValueVector* srcNodeVector, common::ValueVector* dstNodeVector,
        common::ValueVector* relIDVector, common::ValueVector* propertyVector);

    void logLoadExtension(std::string path);

    void logBeginTransaction();
    void logCommit();

    void clear();
    uint64_t getSize();

private:
    void addNewWALRecord(const WALRecord& walRecord);
    // Flush buffered WAL records to the global WAL file if size exceeds threshold.
    // Must be called with mtx held.
    void flushIfNeededNoLock();

private:
    std::mutex mtx;
    std::shared_ptr<common::InMemFileWriter> writer;
    std::unique_ptr<common::Serializer> serializer;
    // Mid-transaction flush context (optional — only set for write transactions on disk DBs).
    WAL* globalWAL = nullptr;
    main::ClientContext* clientContext = nullptr;
    uint64_t walFlushThreshold = DEFAULT_WAL_FLUSH_THRESHOLD;
};

} // namespace storage
} // namespace kuzu
