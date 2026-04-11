#include "index/secondary_range_index.h"

#include <algorithm>

#include "common/serializer/deserializer.h"
#include "common/serializer/serializer.h"
#include "main/client_context.h"

namespace kuzu {
namespace range_index_extension {

using namespace kuzu::storage;
using namespace kuzu::common;

// ===========================================================================
// SecondaryRangeIndexStorageInfo
// ===========================================================================
std::shared_ptr<BufferWriter> SecondaryRangeIndexStorageInfo::serialize() const {
    auto bufferWriter = std::make_shared<BufferWriter>();
    auto serializer = Serializer(bufferWriter);
    serializer.write<uint64_t>(numEntries);
    serializer.write<column_id_t>(columnID);
    uint64_t dataSize = serializedData.size();
    serializer.write<uint64_t>(dataSize);
    if (dataSize > 0) {
        serializer.write(serializedData.data(), dataSize);
    }
    return bufferWriter;
}

std::unique_ptr<IndexStorageInfo> SecondaryRangeIndexStorageInfo::deserialize(
    std::unique_ptr<BufferReader> reader) {
    uint64_t numEntries = 0;
    column_id_t columnID = INVALID_COLUMN_ID;
    Deserializer deSer{std::move(reader)};
    deSer.deserializeValue<uint64_t>(numEntries);
    deSer.deserializeValue<column_id_t>(columnID);
    auto si = std::make_unique<SecondaryRangeIndexStorageInfo>(numEntries, columnID);
    if (!deSer.finished()) {
        uint64_t dataSize = 0;
        deSer.deserializeValue<uint64_t>(dataSize);
        if (dataSize > 0) {
            si->serializedData.resize(dataSize);
            deSer.read(si->serializedData.data(), dataSize);
        }
    }
    return si;
}

// ===========================================================================
// TypedInnerRangeIndex – template methods
// ===========================================================================
template<typename T>
auto TypedInnerRangeIndex<T>::extractKey(const uint8_t* data) const -> KeyType {
    if constexpr (std::is_same_v<T, ku_string_t>) {
        auto kuStr = reinterpret_cast<const ku_string_t*>(data);
        return kuStr->getAsString();
    } else {
        return *reinterpret_cast<const T*>(data);
    }
}

template<typename T>
void TypedInnerRangeIndex<T>::insertEntry(const uint8_t* keyData, offset_t nodeOffset) {
    auto key = extractKey(keyData);
    entries[key].push_back(nodeOffset);
    reverseMap[nodeOffset] = key;
    totalEntries++;
}

template<typename T>
void TypedInnerRangeIndex<T>::deleteEntry(const uint8_t* keyData, offset_t nodeOffset) {
    auto key = extractKey(keyData);
    auto it = entries.find(key);
    if (it != entries.end()) {
        auto& offsets = it->second;
        auto pos = std::find(offsets.begin(), offsets.end(), nodeOffset);
        if (pos != offsets.end()) {
            offsets.erase(pos);
            totalEntries--;
            if (offsets.empty()) {
                entries.erase(it);
            }
        }
    }
}

template<typename T>
bool TypedInnerRangeIndex<T>::lookupOffsets(const uint8_t* keyData,
    std::vector<offset_t>& result) const {
    auto key = extractKey(keyData);
    auto it = entries.find(key);
    if (it != entries.end() && !it->second.empty()) {
        result = it->second;
        return true;
    }
    return false;
}

template<typename T>
void TypedInnerRangeIndex<T>::rangeLookup(const uint8_t* minKey, const uint8_t* maxKey,
    bool hasMin, bool hasMax,
    std::vector<offset_t>& result,
    bool minInclusive, bool maxInclusive) const {
    typename std::map<KeyType, std::vector<offset_t>>::const_iterator itBegin;
    typename std::map<KeyType, std::vector<offset_t>>::const_iterator itEnd;
    if (hasMin) {
        auto minVal = extractKey(minKey);
        if (minInclusive) {
            itBegin = entries.lower_bound(minVal); // >= minVal
        } else {
            itBegin = entries.upper_bound(minVal); // > minVal
        }
    } else {
        itBegin = entries.begin();
    }
    if (hasMax) {
        auto maxVal = extractKey(maxKey);
        if (maxInclusive) {
            itEnd = entries.upper_bound(maxVal); // <= maxVal
        } else {
            itEnd = entries.lower_bound(maxVal); // < maxVal
        }
    } else {
        itEnd = entries.end();
    }
    for (auto it = itBegin; it != itEnd; ++it) {
        result.insert(result.end(), it->second.begin(), it->second.end());
    }
}

template<typename T>
void TypedInnerRangeIndex<T>::deleteByOffset(offset_t nodeOffset) {
    auto revIt = reverseMap.find(nodeOffset);
    if (revIt == reverseMap.end()) {
        return;
    }
    auto& key = revIt->second;
    auto it = entries.find(key);
    if (it != entries.end()) {
        auto& offsets = it->second;
        auto pos = std::find(offsets.begin(), offsets.end(), nodeOffset);
        if (pos != offsets.end()) {
            offsets.erase(pos);
            totalEntries--;
            if (offsets.empty()) {
                entries.erase(it);
            }
        }
    }
    reverseMap.erase(revIt);
}

template<typename T>
void TypedInnerRangeIndex<T>::serializeEntries(Serializer& serializer) const {
    uint64_t numKeys = entries.size();
    serializer.write<uint64_t>(numKeys);
    for (auto& [key, offsets] : entries) {
        if constexpr (std::is_same_v<KeyType, std::string>) {
            serializer.write<std::string>(key);
        } else {
            serializer.write<KeyType>(key);
        }
        serializer.serializeVector(offsets);
    }
}

template<typename T>
void TypedInnerRangeIndex<T>::deserializeEntries(Deserializer& deserializer) {
    entries.clear();
    reverseMap.clear();
    totalEntries = 0;
    uint64_t numKeys = 0;
    deserializer.deserializeValue<uint64_t>(numKeys);
    for (uint64_t i = 0; i < numKeys; i++) {
        KeyType key;
        if constexpr (std::is_same_v<KeyType, std::string>) {
            deserializer.deserializeValue<std::string>(key);
        } else {
            deserializer.deserializeValue<KeyType>(key);
        }
        std::vector<offset_t> offsets;
        deserializer.deserializeVector(offsets);
        for (auto off : offsets) {
            reverseMap[off] = key;
        }
        totalEntries += offsets.size();
        entries[std::move(key)] = std::move(offsets);
    }
}

// Explicit instantiations for supported types.
template class TypedInnerRangeIndex<int64_t>;
template class TypedInnerRangeIndex<int32_t>;
template class TypedInnerRangeIndex<double>;
template class TypedInnerRangeIndex<float>;
template class TypedInnerRangeIndex<ku_string_t>;
template class TypedInnerRangeIndex<int16_t>;
template class TypedInnerRangeIndex<int128_t>;
template class TypedInnerRangeIndex<uint64_t>;
template class TypedInnerRangeIndex<uint32_t>;

// ===========================================================================
// SecondaryRangeIndex – Insert / Delete / Update states (minimal)
// ===========================================================================
struct RangeInsertState final : Index::InsertState {
    ~RangeInsertState() override = default;
};

struct RangeDeleteState final : Index::DeleteState {
    ~RangeDeleteState() override = default;
};

struct RangeUpdateState final : Index::UpdateState {
    column_id_t columnID;
    explicit RangeUpdateState(column_id_t columnID) : columnID{columnID} {}
    ~RangeUpdateState() override = default;
};

// ===========================================================================
// SecondaryRangeIndex – construction / load
// ===========================================================================
SecondaryRangeIndex::SecondaryRangeIndex(IndexInfo indexInfo,
    std::unique_ptr<IndexStorageInfo> storageInfoArg)
    : Index{std::move(indexInfo), std::move(storageInfoArg)} {
    initInnerIndex();
    auto& si = storageInfo->cast<SecondaryRangeIndexStorageInfo>();
    if (!si.serializedData.empty()) {
        auto reader =
            std::make_unique<BufferReader>(si.serializedData.data(), si.serializedData.size());
        Deserializer deSer{std::move(reader)};
        innerIndex->deserializeEntries(deSer);
    }
}

std::unique_ptr<Index> SecondaryRangeIndex::load(main::ClientContext* /*context*/,
    StorageManager* /*storageManager*/, IndexInfo indexInfo,
    std::span<uint8_t> storageInfoBuffer) {
    auto reader =
        std::make_unique<BufferReader>(storageInfoBuffer.data(), storageInfoBuffer.size());
    auto si = SecondaryRangeIndexStorageInfo::deserialize(std::move(reader));
    return std::make_unique<SecondaryRangeIndex>(std::move(indexInfo), std::move(si));
}

void SecondaryRangeIndex::initInnerIndex() {
    KU_ASSERT(!indexInfo.keyDataTypes.empty());
    auto physType = indexInfo.keyDataTypes[0];
    TypeUtils::visit(
        physType,
        [&](ku_string_t) {
            innerIndex = std::make_unique<TypedInnerRangeIndex<ku_string_t>>();
        },
        [&]<HashablePrimitive T>(T) {
            innerIndex = std::make_unique<TypedInnerRangeIndex<T>>();
        },
        [&](auto) { KU_UNREACHABLE; });
}

// ===========================================================================
// SecondaryRangeIndex – Index interface implementation
// ===========================================================================
std::unique_ptr<Index::InsertState> SecondaryRangeIndex::initInsertState(
    main::ClientContext* /*context*/, visible_func /*isVisible*/) {
    return std::make_unique<RangeInsertState>();
}

void SecondaryRangeIndex::insert(transaction::Transaction* /*transaction*/,
    const ValueVector& nodeIDVector, const std::vector<ValueVector*>& indexVectors,
    InsertState& /*insertState*/) {
    KU_ASSERT(!indexVectors.empty());
    auto& si = storageInfo->cast<SecondaryRangeIndexStorageInfo>();
    std::lock_guard<std::mutex> lock(mtx);
    for (auto i = 0u; i < nodeIDVector.state->getSelSize(); i++) {
        auto pos = nodeIDVector.state->getSelVector()[i];
        auto nodeOffset = nodeIDVector.getValue<internalID_t>(pos).offset;
        auto* propVector = indexVectors[0];
        if (propVector->isNull(pos)) continue;
        auto* keyData = propVector->getData() + propVector->getNumBytesPerValue() * pos;
        innerIndex->insertEntry(keyData, nodeOffset);
    }
    si.numEntries = innerIndex->size();
}

std::unique_ptr<Index::UpdateState> SecondaryRangeIndex::initUpdateState(
    main::ClientContext* /*context*/, column_id_t columnID, visible_func /*isVisible*/) {
    return std::make_unique<RangeUpdateState>(columnID);
}

void SecondaryRangeIndex::update(transaction::Transaction* /*transaction*/,
    const ValueVector& nodeIDVector, ValueVector& propertyVector,
    UpdateState& /*updateState*/) {
    auto& si = storageInfo->cast<SecondaryRangeIndexStorageInfo>();
    std::lock_guard<std::mutex> lock(mtx);
    for (auto i = 0u; i < nodeIDVector.state->getSelSize(); i++) {
        auto pos = nodeIDVector.state->getSelVector()[i];
        auto nodeOffset = nodeIDVector.getValue<internalID_t>(pos).offset;
        innerIndex->deleteByOffset(nodeOffset);
        if (!propertyVector.isNull(pos)) {
            auto* keyData = propertyVector.getData() + propertyVector.getNumBytesPerValue() * pos;
            innerIndex->insertEntry(keyData, nodeOffset);
        }
    }
    si.numEntries = innerIndex->size();
}

std::unique_ptr<Index::DeleteState> SecondaryRangeIndex::initDeleteState(
    const transaction::Transaction* /*transaction*/, MemoryManager* /*mm*/,
    visible_func /*isVisible*/) {
    return std::make_unique<RangeDeleteState>();
}

void SecondaryRangeIndex::delete_(transaction::Transaction* /*transaction*/,
    const ValueVector& nodeIDVector, DeleteState& /*deleteState*/) {
    std::lock_guard<std::mutex> lock(mtx);
    for (auto i = 0u; i < nodeIDVector.state->getSelSize(); i++) {
        auto pos = nodeIDVector.state->getSelVector()[i];
        auto nodeOffset = nodeIDVector.getValue<internalID_t>(pos).offset;
        innerIndex->deleteByOffset(nodeOffset);
    }
    auto& si = storageInfo->cast<SecondaryRangeIndexStorageInfo>();
    si.numEntries = innerIndex->size();
}

void SecondaryRangeIndex::checkpoint(main::ClientContext* /*context*/,
    PageAllocator& /*pageAllocator*/) {
    std::lock_guard<std::mutex> lock(mtx);
    auto& si = storageInfo->cast<SecondaryRangeIndexStorageInfo>();
    si.numEntries = innerIndex->size();
    auto entryWriter = std::make_shared<BufferWriter>();
    auto serializer = Serializer(entryWriter);
    innerIndex->serializeEntries(serializer);
    auto data = entryWriter->getData();
    si.serializedData.assign(data.data.get(), data.data.get() + data.size);
}

bool SecondaryRangeIndex::lookup(const uint8_t* keyData,
    std::vector<offset_t>& result) const {
    std::lock_guard<std::mutex> lock(mtx);
    return innerIndex->lookupOffsets(keyData, result);
}

bool SecondaryRangeIndex::rangeLookup(const uint8_t* minKey, const uint8_t* maxKey,
    bool hasMin, bool hasMax, std::vector<offset_t>& result,
    bool minInclusive, bool maxInclusive) const {
    std::lock_guard<std::mutex> lock(mtx);
    innerIndex->rangeLookup(minKey, maxKey, hasMin, hasMax, result, minInclusive, maxInclusive);
    return !result.empty();
}

} // namespace range_index_extension
} // namespace kuzu

