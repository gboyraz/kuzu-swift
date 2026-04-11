#pragma once

#include <mutex>
#include <unordered_map>
#include <vector>

#include "catalog/catalog_entry/index_catalog_entry.h"
#include "common/serializer/buffer_reader.h"
#include "common/serializer/buffer_writer.h"
#include "common/serializer/deserializer.h"
#include "common/serializer/serializer.h"
#include "common/type_utils.h"
#include "common/types/ku_string.h"
#include "storage/buffer_manager/memory_manager.h"
#include "storage/index/index.h"

namespace kuzu {
namespace hash_index_extension {

// ---------------------------------------------------------------------------
// Catalog aux info for hash index (minimal — no extra data to persist)
// ---------------------------------------------------------------------------
struct HashIndexAuxInfo final : catalog::IndexAuxInfo {
    std::shared_ptr<common::BufferWriter> serialize() const override {
        return std::make_shared<common::BufferWriter>(0);
    }
    std::unique_ptr<IndexAuxInfo> copy() override {
        return std::make_unique<HashIndexAuxInfo>();
    }
    std::string toCypher(const catalog::IndexCatalogEntry& indexEntry,
        const catalog::ToCypherInfo& /*info*/) const override {
        return "CALL CREATE_HASH_INDEX('" + indexEntry.getIndexName() + "', '" +
               indexEntry.getIndexName() + "');";
    }
};

// ---------------------------------------------------------------------------
// Storage info persisted alongside the index
// ---------------------------------------------------------------------------
struct SecondaryHashIndexStorageInfo final : storage::IndexStorageInfo {
    uint64_t numEntries = 0;
    common::column_id_t columnID = common::INVALID_COLUMN_ID;
    std::vector<uint8_t> serializedData; // checkpoint entry data

    SecondaryHashIndexStorageInfo() = default;
    SecondaryHashIndexStorageInfo(uint64_t numEntries, common::column_id_t columnID)
        : numEntries{numEntries}, columnID{columnID} {}

    std::shared_ptr<common::BufferWriter> serialize() const override;
    static std::unique_ptr<IndexStorageInfo> deserialize(
        std::unique_ptr<common::BufferReader> reader);
};

// ---------------------------------------------------------------------------
// Type-erased inner index – one concrete instantiation per PhysicalTypeID
// ---------------------------------------------------------------------------
class InnerSecondaryIndex {
public:
    virtual ~InnerSecondaryIndex() = default;
    virtual void insertEntry(const uint8_t* keyData, common::offset_t nodeOffset) = 0;
    virtual void deleteEntry(const uint8_t* keyData, common::offset_t nodeOffset) = 0;
    virtual void deleteByOffset(common::offset_t nodeOffset) = 0;
    virtual bool lookupOffsets(const uint8_t* keyData,
        std::vector<common::offset_t>& result) const = 0;
    virtual uint64_t size() const = 0;
    virtual void clear() = 0;
    virtual void serializeEntries(common::Serializer& serializer) const = 0;
    virtual void deserializeEntries(common::Deserializer& deserializer) = 0;
};

template<typename T>
class TypedInnerSecondaryIndex final : public InnerSecondaryIndex {
    using KeyType = std::conditional_t<std::is_same_v<T, common::ku_string_t>, std::string, T>;

public:
    void insertEntry(const uint8_t* keyData, common::offset_t nodeOffset) override;
    void deleteEntry(const uint8_t* keyData, common::offset_t nodeOffset) override;
    void deleteByOffset(common::offset_t nodeOffset) override;
    bool lookupOffsets(const uint8_t* keyData,
        std::vector<common::offset_t>& result) const override;
    uint64_t size() const override { return totalEntries; }
    void clear() override {
        entries.clear();
        reverseMap.clear();
        totalEntries = 0;
    }
    void serializeEntries(common::Serializer& serializer) const override;
    void deserializeEntries(common::Deserializer& deserializer) override;

private:
    KeyType extractKey(const uint8_t* data) const;
    std::unordered_map<KeyType, std::vector<common::offset_t>> entries;
    std::unordered_map<common::offset_t, KeyType> reverseMap; // offset → key for deletion
    uint64_t totalEntries = 0;
};

// ---------------------------------------------------------------------------
// SecondaryHashIndex – extends Index
// ---------------------------------------------------------------------------
class SecondaryHashIndex final : public storage::Index {
public:
    // Construct for a freshly-created index.
    SecondaryHashIndex(storage::IndexInfo indexInfo,
        std::unique_ptr<storage::IndexStorageInfo> storageInfo);

    // Load from disk.
    static std::unique_ptr<Index> load(main::ClientContext* context,
        storage::StorageManager* storageManager, storage::IndexInfo indexInfo,
        std::span<uint8_t> storageInfoBuffer);

    // Index interface
    std::unique_ptr<InsertState> initInsertState(main::ClientContext* context,
        storage::visible_func isVisible) override;

    void insert(transaction::Transaction* transaction, const common::ValueVector& nodeIDVector,
        const std::vector<common::ValueVector*>& indexVectors, InsertState& insertState) override;

    std::unique_ptr<UpdateState> initUpdateState(main::ClientContext* context,
        common::column_id_t columnID, storage::visible_func isVisible) override;

    void update(transaction::Transaction* transaction, const common::ValueVector& nodeIDVector,
        common::ValueVector& propertyVector, UpdateState& updateState) override;

    std::unique_ptr<DeleteState> initDeleteState(const transaction::Transaction* transaction,
        storage::MemoryManager* mm, storage::visible_func isVisible) override;

    void delete_(transaction::Transaction* transaction, const common::ValueVector& nodeIDVector,
        DeleteState& deleteState) override;

    void checkpoint(main::ClientContext* context, storage::PageAllocator& pageAllocator) override;

    static storage::IndexType getIndexType() {
        static const storage::IndexType SECONDARY_HASH_TYPE{"HASH",
            storage::IndexConstraintType::SECONDARY_NON_UNIQUE,
            storage::IndexDefinitionType::EXTENSION, load};
        return SECONDARY_HASH_TYPE;
    }

    // Public lookup API for query functions.
    bool lookup(const uint8_t* keyData, std::vector<common::offset_t>& result) const;

private:
    void initInnerIndex();

    std::unique_ptr<InnerSecondaryIndex> innerIndex;
    mutable std::mutex mtx;
};

} // namespace hash_index_extension
} // namespace kuzu

