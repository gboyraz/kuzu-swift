#pragma once

#include <map>
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
namespace range_index_extension {

// ---------------------------------------------------------------------------
// Catalog aux info for range index (minimal — no extra data to persist)
// ---------------------------------------------------------------------------
struct RangeIndexAuxInfo final : catalog::IndexAuxInfo {
    std::shared_ptr<common::BufferWriter> serialize() const override {
        return std::make_shared<common::BufferWriter>(0);
    }
    std::unique_ptr<IndexAuxInfo> copy() override {
        return std::make_unique<RangeIndexAuxInfo>();
    }
    std::string toCypher(const catalog::IndexCatalogEntry& indexEntry,
        const catalog::ToCypherInfo& /*info*/) const override {
        return "CALL CREATE_RANGE_INDEX('" + indexEntry.getIndexName() + "', '" +
               indexEntry.getIndexName() + "');";
    }
};

// ---------------------------------------------------------------------------
// Storage info persisted alongside the index
// ---------------------------------------------------------------------------
struct SecondaryRangeIndexStorageInfo final : storage::IndexStorageInfo {
    uint64_t numEntries = 0;
    common::column_id_t columnID = common::INVALID_COLUMN_ID;
    std::vector<uint8_t> serializedData;

    SecondaryRangeIndexStorageInfo() = default;
    SecondaryRangeIndexStorageInfo(uint64_t numEntries, common::column_id_t columnID)
        : numEntries{numEntries}, columnID{columnID} {}

    std::shared_ptr<common::BufferWriter> serialize() const override;
    static std::unique_ptr<IndexStorageInfo> deserialize(
        std::unique_ptr<common::BufferReader> reader);
};

// ---------------------------------------------------------------------------
// Type-erased inner index – one concrete instantiation per PhysicalTypeID
// ---------------------------------------------------------------------------
class InnerRangeIndex {
public:
    virtual ~InnerRangeIndex() = default;
    virtual void insertEntry(const uint8_t* keyData, common::offset_t nodeOffset) = 0;
    virtual void deleteEntry(const uint8_t* keyData, common::offset_t nodeOffset) = 0;
    virtual void deleteByOffset(common::offset_t nodeOffset) = 0;
    virtual bool lookupOffsets(const uint8_t* keyData,
        std::vector<common::offset_t>& result) const = 0;
    virtual void rangeLookup(const uint8_t* minKey, const uint8_t* maxKey,
        bool hasMin, bool hasMax,
        std::vector<common::offset_t>& result,
        bool minInclusive = true, bool maxInclusive = true) const = 0;
    virtual uint64_t size() const = 0;
    virtual void clear() = 0;
    virtual void serializeEntries(common::Serializer& serializer) const = 0;
    virtual void deserializeEntries(common::Deserializer& deserializer) = 0;
};

template<typename T>
class TypedInnerRangeIndex final : public InnerRangeIndex {
    using KeyType = std::conditional_t<std::is_same_v<T, common::ku_string_t>, std::string, T>;

public:
    void insertEntry(const uint8_t* keyData, common::offset_t nodeOffset) override;
    void deleteEntry(const uint8_t* keyData, common::offset_t nodeOffset) override;
    void deleteByOffset(common::offset_t nodeOffset) override;
    bool lookupOffsets(const uint8_t* keyData,
        std::vector<common::offset_t>& result) const override;
    void rangeLookup(const uint8_t* minKey, const uint8_t* maxKey,
        bool hasMin, bool hasMax,
        std::vector<common::offset_t>& result,
        bool minInclusive = true, bool maxInclusive = true) const override;
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
    std::map<KeyType, std::vector<common::offset_t>> entries;       // sorted by key
    std::unordered_map<common::offset_t, KeyType> reverseMap;       // offset → key
    uint64_t totalEntries = 0;
};

// ---------------------------------------------------------------------------
// SecondaryRangeIndex – extends Index
// ---------------------------------------------------------------------------
class SecondaryRangeIndex final : public storage::Index {
public:
    SecondaryRangeIndex(storage::IndexInfo indexInfo,
        std::unique_ptr<storage::IndexStorageInfo> storageInfo);

    static std::unique_ptr<Index> load(main::ClientContext* context,
        storage::StorageManager* storageManager, storage::IndexInfo indexInfo,
        std::span<uint8_t> storageInfoBuffer);

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
        static const storage::IndexType SECONDARY_RANGE_TYPE{"RANGE",
            storage::IndexConstraintType::SECONDARY_NON_UNIQUE,
            storage::IndexDefinitionType::EXTENSION, load};
        return SECONDARY_RANGE_TYPE;
    }

    bool lookup(const uint8_t* keyData, std::vector<common::offset_t>& result) const override;
    bool rangeLookup(const uint8_t* minKey, const uint8_t* maxKey,
        bool hasMin, bool hasMax, std::vector<common::offset_t>& result,
        bool minInclusive = true, bool maxInclusive = true) const override;

private:
    void initInnerIndex();
    std::unique_ptr<InnerRangeIndex> innerIndex;
    mutable std::mutex mtx;
};

} // namespace range_index_extension
} // namespace kuzu

