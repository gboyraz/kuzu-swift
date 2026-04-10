#include "storage/wal/local_wal.h"

#include "binder/ddl/bound_alter_info.h"
#include "catalog/catalog_entry/sequence_catalog_entry.h"
#include "common/serializer/in_mem_file_writer.h"
#include "common/serializer/serializer.h"
#include "common/vector/value_vector.h"
#include "storage/wal/wal.h"

using namespace kuzu::catalog;
using namespace kuzu::common;
using namespace kuzu::binder;

namespace kuzu {
namespace storage {

LocalWAL::LocalWAL(MemoryManager& mm) {
    writer = std::make_shared<InMemFileWriter>(mm);
    serializer = std::make_unique<Serializer>(writer);
}

void LocalWAL::setFlushContext(WAL* globalWAL_, main::ClientContext* context,
    uint64_t flushThreshold) {
    std::unique_lock lck{mtx};
    globalWAL = globalWAL_;
    clientContext = context;
    walFlushThreshold = flushThreshold;
}

void LocalWAL::logBeginTransaction() {
    BeginTransactionRecord walRecord;
    addNewWALRecord(walRecord);
}

void LocalWAL::logCommit() {
    CommitRecord walRecord;
    addNewWALRecord(walRecord);
}

void LocalWAL::logCreateCatalogEntryRecord(CatalogEntry* catalogEntry, bool isInternal) {
    CreateCatalogEntryRecord walRecord(catalogEntry, isInternal);
    addNewWALRecord(walRecord);
}

void LocalWAL::logDropCatalogEntryRecord(table_id_t tableID, CatalogEntryType type) {
    DropCatalogEntryRecord walRecord(tableID, type);
    addNewWALRecord(walRecord);
}

void LocalWAL::logAlterCatalogEntryRecord(const BoundAlterInfo* alterInfo) {
    AlterTableEntryRecord walRecord(alterInfo);
    addNewWALRecord(walRecord);
}

void LocalWAL::logTableInsertion(table_id_t tableID, TableType tableType, row_idx_t numRows,
    const std::vector<ValueVector*>& vectors) {
    TableInsertionRecord walRecord(tableID, tableType, numRows, vectors);
    addNewWALRecord(walRecord);
}

void LocalWAL::logNodeDeletion(table_id_t tableID, offset_t nodeOffset, ValueVector* pkVector) {
    NodeDeletionRecord walRecord(tableID, nodeOffset, pkVector);
    addNewWALRecord(walRecord);
}

void LocalWAL::logNodeUpdate(table_id_t tableID, column_id_t columnID, offset_t nodeOffset,
    ValueVector* propertyVector) {
    NodeUpdateRecord walRecord(tableID, columnID, nodeOffset, propertyVector);
    addNewWALRecord(walRecord);
}

void LocalWAL::logRelDelete(table_id_t tableID, ValueVector* srcNodeVector,
    ValueVector* dstNodeVector, ValueVector* relIDVector) {
    RelDeletionRecord walRecord(tableID, srcNodeVector, dstNodeVector, relIDVector);
    addNewWALRecord(walRecord);
}

void LocalWAL::logRelDetachDelete(table_id_t tableID, RelDataDirection direction,
    ValueVector* srcNodeVector) {
    RelDetachDeleteRecord walRecord(tableID, direction, srcNodeVector);
    addNewWALRecord(walRecord);
}

void LocalWAL::logRelUpdate(table_id_t tableID, column_id_t columnID, ValueVector* srcNodeVector,
    ValueVector* dstNodeVector, ValueVector* relIDVector, ValueVector* propertyVector) {
    RelUpdateRecord walRecord(tableID, columnID, srcNodeVector, dstNodeVector, relIDVector,
        propertyVector);
    addNewWALRecord(walRecord);
}

void LocalWAL::logUpdateSequenceRecord(sequence_id_t sequenceID, uint64_t kCount) {
    UpdateSequenceRecord walRecord(sequenceID, kCount);
    addNewWALRecord(walRecord);
}

void LocalWAL::logLoadExtension(std::string path) {
    LoadExtensionRecord walRecord(std::move(path));
    addNewWALRecord(walRecord);
}

// NOLINTNEXTLINE(readability-make-member-function-const): semantically non-const function.
void LocalWAL::clear() {
    std::unique_lock lck{mtx};
    writer->clear();
}

uint64_t LocalWAL::getSize() {
    std::unique_lock lck{mtx};
    return writer->getSize();
}

// NOLINTNEXTLINE(readability-make-member-function-const): semantically non-const function.
void LocalWAL::addNewWALRecord(const WALRecord& walRecord) {
    std::unique_lock lck{mtx};
    KU_ASSERT(walRecord.type != WALRecordType::INVALID_RECORD);
    walRecord.serialize(*serializer);
    flushIfNeededNoLock();
}

// NOLINTNEXTLINE(readability-make-member-function-const): semantically non-const function.
void LocalWAL::flushIfNeededNoLock() {
    if (!globalWAL || !clientContext) {
        return;
    }
    if (writer->getSize() >= walFlushThreshold) {
        // Flush buffered in-memory WAL records to the global WAL file on disk,
        // then clear the in-memory buffer to reclaim memory.
        globalWAL->flushLocalWALNoCommit(*this, clientContext);
        writer->clear();
    }
}

} // namespace storage
} // namespace kuzu
