#include "index/secondary_hash_index.h"

#include <algorithm>

#include "common/serializer/deserializer.h"
#include "common/serializer/serializer.h"
#include "main/client_context.h"

namespace kuzu {
namespace hash_index_extension {

using namespace kuzu::storage;
using namespace kuzu::common;

// ===========================================================================
// SecondaryHashIndexStorageInfo
// ===========================================================================
std::shared_ptr<BufferWriter> SecondaryHashIndexStorageInfo::serialize() const {
    auto bufferWriter = std::make_shared<BufferWriter>();
    auto serializer = Serializer(bufferWriter);
    serializer.write<uint64_t>(numEntries);
    serializer.write<column_id_t>(columnID);
    // Write serialized entry data length + bytes
    uint64_t dataSize = serializedData.size();
    serializer.write<uint64_t>(dataSize);
    if (dataSize > 0) {
        serializer.write(serializedData.data(), dataSize);
    }
    // Write composite index data
    uint64_t numCompositeColumns = columnIDs.size();
    serializer.write<uint64_t>(numCompositeColumns);
    for (auto cid : columnIDs) {
        serializer.write<column_id_t>(cid);
    }
    uint64_t numPropNames = propertyNames.size();
    serializer.write<uint64_t>(numPropNames);
    for (auto& pn : propertyNames) {
        serializer.write<std::string>(pn);
    }
    return bufferWriter;
}

std::unique_ptr<IndexStorageInfo> SecondaryHashIndexStorageInfo::deserialize(
    std::unique_ptr<BufferReader> reader) {
    uint64_t numEntries = 0;
    column_id_t columnID = INVALID_COLUMN_ID;
    Deserializer deSer{std::move(reader)};
    deSer.deserializeValue<uint64_t>(numEntries);
    deSer.deserializeValue<column_id_t>(columnID);
    auto si = std::make_unique<SecondaryHashIndexStorageInfo>(numEntries, columnID);
    // Read serialized entry data if present
    if (!deSer.finished()) {
        uint64_t dataSize = 0;
        deSer.deserializeValue<uint64_t>(dataSize);
        if (dataSize > 0) {
            si->serializedData.resize(dataSize);
            deSer.read(si->serializedData.data(), dataSize);
        }
    }
    // Read composite index data if present
    if (!deSer.finished()) {
        uint64_t numCompositeColumns = 0;
        deSer.deserializeValue<uint64_t>(numCompositeColumns);
        si->columnIDs.resize(numCompositeColumns);
        for (uint64_t i = 0; i < numCompositeColumns; i++) {
            deSer.deserializeValue<column_id_t>(si->columnIDs[i]);
        }
        uint64_t numPropNames = 0;
        deSer.deserializeValue<uint64_t>(numPropNames);
        si->propertyNames.resize(numPropNames);
        for (uint64_t i = 0; i < numPropNames; i++) {
            deSer.deserializeValue<std::string>(si->propertyNames[i]);
        }
    }
    return si;
}

// ===========================================================================
// TypedInnerSecondaryIndex – template methods
// ===========================================================================
template<typename T>
auto TypedInnerSecondaryIndex<T>::extractKey(const uint8_t* data) const -> KeyType {
    if constexpr (std::is_same_v<T, ku_string_t>) {
        auto kuStr = reinterpret_cast<const ku_string_t*>(data);
        return kuStr->getAsString();
    } else {
        return *reinterpret_cast<const T*>(data);
    }
}

template<typename T>
void TypedInnerSecondaryIndex<T>::insertEntry(const uint8_t* keyData, offset_t nodeOffset) {
    auto key = extractKey(keyData);
    entries[key].push_back(nodeOffset);
    reverseMap[nodeOffset] = key;
    totalEntries++;
}

template<typename T>
void TypedInnerSecondaryIndex<T>::deleteEntry(const uint8_t* keyData, offset_t nodeOffset) {
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
bool TypedInnerSecondaryIndex<T>::lookupOffsets(const uint8_t* keyData,
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
void TypedInnerSecondaryIndex<T>::deleteByOffset(offset_t nodeOffset) {
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
void TypedInnerSecondaryIndex<T>::serializeEntries(Serializer& serializer) const {
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
void TypedInnerSecondaryIndex<T>::deserializeEntries(Deserializer& deserializer) {
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
template class TypedInnerSecondaryIndex<int64_t>;
template class TypedInnerSecondaryIndex<int32_t>;
template class TypedInnerSecondaryIndex<double>;
template class TypedInnerSecondaryIndex<float>;
template class TypedInnerSecondaryIndex<ku_string_t>;
template class TypedInnerSecondaryIndex<int16_t>;
template class TypedInnerSecondaryIndex<int128_t>;
template class TypedInnerSecondaryIndex<uint64_t>;
template class TypedInnerSecondaryIndex<uint32_t>;

// ===========================================================================
// SecondaryHashIndex – Insert / Delete / Update states (minimal)
// ===========================================================================
struct SecondaryInsertState final : Index::InsertState {
    ~SecondaryInsertState() override = default;
};

struct SecondaryDeleteState final : Index::DeleteState {
    ~SecondaryDeleteState() override = default;
};

struct SecondaryUpdateState final : Index::UpdateState {
    column_id_t columnID;
    explicit SecondaryUpdateState(column_id_t columnID) : columnID{columnID} {}
    ~SecondaryUpdateState() override = default;
};

// ===========================================================================
// SecondaryHashIndex – construction / load
// ===========================================================================
SecondaryHashIndex::SecondaryHashIndex(IndexInfo indexInfo,
    std::unique_ptr<IndexStorageInfo> storageInfoArg)
    : Index{std::move(indexInfo), std::move(storageInfoArg)} {
    initInnerIndex();
    // Restore entries from checkpoint data if available
    auto& si = storageInfo->cast<SecondaryHashIndexStorageInfo>();
    if (!si.serializedData.empty()) {
        auto reader =
            std::make_unique<BufferReader>(si.serializedData.data(), si.serializedData.size());
        Deserializer deSer{std::move(reader)};
        innerIndex->deserializeEntries(deSer);
    }
}

std::unique_ptr<Index> SecondaryHashIndex::load(main::ClientContext* /*context*/,
    StorageManager* /*storageManager*/, IndexInfo indexInfo,
    std::span<uint8_t> storageInfoBuffer) {
    auto reader =
        std::make_unique<BufferReader>(storageInfoBuffer.data(), storageInfoBuffer.size());
    auto si = SecondaryHashIndexStorageInfo::deserialize(std::move(reader));
    return std::make_unique<SecondaryHashIndex>(std::move(indexInfo), std::move(si));
}

void SecondaryHashIndex::initInnerIndex() {
    KU_ASSERT(!indexInfo.keyDataTypes.empty());
    auto physType = indexInfo.keyDataTypes[0];
    TypeUtils::visit(
        physType,
        [&](ku_string_t) {
            innerIndex = std::make_unique<TypedInnerSecondaryIndex<ku_string_t>>();
        },
        [&]<HashablePrimitive T>(T) {
            innerIndex = std::make_unique<TypedInnerSecondaryIndex<T>>();
        },
        [&](auto) { KU_UNREACHABLE; });
}

// ===========================================================================
// SecondaryHashIndex – Index interface implementation
// ===========================================================================
std::unique_ptr<Index::InsertState> SecondaryHashIndex::initInsertState(
    main::ClientContext* /*context*/, visible_func /*isVisible*/) {
    return std::make_unique<SecondaryInsertState>();
}

// Helper: extract a string representation from a ValueVector at given position.
static std::string vectorValueToString(const ValueVector* vec, sel_t pos) {
    return TypeUtils::entryToString(vec->dataType,
        vec->getData() + vec->getNumBytesPerValue() * pos, const_cast<ValueVector*>(vec));
}

void SecondaryHashIndex::insert(transaction::Transaction* /*transaction*/,
    const ValueVector& nodeIDVector, const std::vector<ValueVector*>& indexVectors,
    InsertState& /*insertState*/) {
    KU_ASSERT(!indexVectors.empty());
    auto& si = storageInfo->cast<SecondaryHashIndexStorageInfo>();
    const bool composite = si.isComposite();
    std::lock_guard<std::mutex> lock(mtx);
    for (auto i = 0u; i < nodeIDVector.state->getSelSize(); i++) {
        auto pos = nodeIDVector.state->getSelVector()[i];
        auto nodeOffset = nodeIDVector.getValue<internalID_t>(pos).offset;
        if (composite) {
            // Check if ANY property is null — skip entire row if so
            bool hasNull = false;
            for (auto* vec : indexVectors) {
                if (vec->isNull(pos)) {
                    hasNull = true;
                    break;
                }
            }
            if (hasNull) continue;
            // Build composite key from all property vectors
            std::vector<std::string> parts;
            parts.reserve(indexVectors.size());
            for (auto* vec : indexVectors) {
                parts.push_back(vectorValueToString(vec, pos));
            }
            auto compositeKey = buildCompositeKey(parts);
            ku_string_t kuStr(compositeKey.data(), compositeKey.size());
            innerIndex->insertEntry(reinterpret_cast<const uint8_t*>(&kuStr), nodeOffset);
        } else {
            auto* propVector = indexVectors[0];
            if (propVector->isNull(pos)) continue;
            auto* keyData = propVector->getData() + propVector->getNumBytesPerValue() * pos;
            innerIndex->insertEntry(keyData, nodeOffset);
        }
    }
    si.numEntries = innerIndex->size();
}

std::unique_ptr<Index::UpdateState> SecondaryHashIndex::initUpdateState(
    main::ClientContext* /*context*/, column_id_t columnID, visible_func /*isVisible*/) {
    return std::make_unique<SecondaryUpdateState>(columnID);
}

void SecondaryHashIndex::update(transaction::Transaction* /*transaction*/,
    const ValueVector& nodeIDVector, ValueVector& propertyVector,
    UpdateState& updateState) {
    auto& si = storageInfo->cast<SecondaryHashIndexStorageInfo>();
    auto& updState = updateState.cast<SecondaryUpdateState>();
    std::lock_guard<std::mutex> lock(mtx);
    for (auto i = 0u; i < nodeIDVector.state->getSelSize(); i++) {
        auto pos = nodeIDVector.state->getSelVector()[i];
        auto nodeOffset = nodeIDVector.getValue<internalID_t>(pos).offset;
        if (si.isComposite()) {
            // For composite: get old composite key, split, replace updated component, rebuild
            auto oldKeyStr = innerIndex->getKeyStringForOffset(nodeOffset);
            innerIndex->deleteByOffset(nodeOffset);
            if (!oldKeyStr.empty() && !propertyVector.isNull(pos)) {
                auto parts = splitCompositeKey(oldKeyStr);
                // Find which position in the composite the updated column occupies
                auto updatedColumnID = updState.columnID;
                for (size_t ci = 0; ci < si.columnIDs.size(); ci++) {
                    if (si.columnIDs[ci] == updatedColumnID) {
                        parts[ci] = vectorValueToString(&propertyVector, pos);
                        break;
                    }
                }
                auto newKey = buildCompositeKey(parts);
                ku_string_t kuStr(newKey.data(), newKey.size());
                innerIndex->insertEntry(reinterpret_cast<const uint8_t*>(&kuStr), nodeOffset);
            }
        } else {
            // Single property update (original behavior)
            innerIndex->deleteByOffset(nodeOffset);
            if (!propertyVector.isNull(pos)) {
                auto* keyData = propertyVector.getData() + propertyVector.getNumBytesPerValue() * pos;
                innerIndex->insertEntry(keyData, nodeOffset);
            }
        }
    }
    si.numEntries = innerIndex->size();
}

std::unique_ptr<Index::DeleteState> SecondaryHashIndex::initDeleteState(
    const transaction::Transaction* /*transaction*/, MemoryManager* /*mm*/,
    visible_func /*isVisible*/) {
    return std::make_unique<SecondaryDeleteState>();
}

void SecondaryHashIndex::delete_(transaction::Transaction* /*transaction*/,
    const ValueVector& nodeIDVector, DeleteState& /*deleteState*/) {
    std::lock_guard<std::mutex> lock(mtx);
    for (auto i = 0u; i < nodeIDVector.state->getSelSize(); i++) {
        auto pos = nodeIDVector.state->getSelVector()[i];
        auto nodeOffset = nodeIDVector.getValue<internalID_t>(pos).offset;
        innerIndex->deleteByOffset(nodeOffset);
    }
    auto& si = storageInfo->cast<SecondaryHashIndexStorageInfo>();
    si.numEntries = innerIndex->size();
}

void SecondaryHashIndex::checkpoint(main::ClientContext* /*context*/,
    PageAllocator& /*pageAllocator*/) {
    std::lock_guard<std::mutex> lock(mtx);
    auto& si = storageInfo->cast<SecondaryHashIndexStorageInfo>();
    si.numEntries = innerIndex->size();
    // Serialize all entries into storageInfo for persistence
    auto entryWriter = std::make_shared<BufferWriter>();
    auto serializer = Serializer(entryWriter);
    innerIndex->serializeEntries(serializer);
    auto data = entryWriter->getData();
    si.serializedData.assign(data.data.get(), data.data.get() + data.size);
}

bool SecondaryHashIndex::lookup(const uint8_t* keyData,
    std::vector<offset_t>& result) const {
    std::lock_guard<std::mutex> lock(mtx);
    return innerIndex->lookupOffsets(keyData, result);
}

bool SecondaryHashIndex::lookupComposite(const std::string& compositeKey,
    std::vector<offset_t>& result) const {
    std::lock_guard<std::mutex> lock(mtx);
    ku_string_t kuStr(compositeKey.data(), compositeKey.size());
    return innerIndex->lookupOffsets(reinterpret_cast<const uint8_t*>(&kuStr), result);
}

std::string SecondaryHashIndex::buildCompositeKey(const std::vector<std::string>& values) {
    std::string result;
    for (size_t i = 0; i < values.size(); i++) {
        if (i > 0) {
            result += '\0';
        }
        result += values[i];
    }
    return result;
}

std::vector<std::string> SecondaryHashIndex::splitCompositeKey(const std::string& compositeKey) {
    std::vector<std::string> parts;
    size_t start = 0;
    for (size_t i = 0; i < compositeKey.size(); i++) {
        if (compositeKey[i] == '\0') {
            parts.push_back(compositeKey.substr(start, i - start));
            start = i + 1;
        }
    }
    parts.push_back(compositeKey.substr(start));
    return parts;
}

bool SecondaryHashIndex::isComposite() const {
    auto& si = storageInfo->cast<SecondaryHashIndexStorageInfo>();
    return si.isComposite();
}

} // namespace hash_index_extension
} // namespace kuzu

