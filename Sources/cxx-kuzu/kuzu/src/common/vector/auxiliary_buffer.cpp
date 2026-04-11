#include "common/vector/auxiliary_buffer.h"

#include <numeric>

#include "common/constants.h"
#include "common/system_config.h"
#include "common/vector/value_vector.h"
#include "storage/buffer_manager/memory_manager.h"

namespace kuzu {
namespace common {

StructAuxiliaryBuffer::StructAuxiliaryBuffer(const LogicalType& type,
    storage::MemoryManager* memoryManager) {
    auto fieldTypes = StructType::getFieldTypes(type);
    childrenVectors.reserve(fieldTypes.size());
    for (const auto& fieldType : fieldTypes) {
        childrenVectors.push_back(std::make_shared<ValueVector>(fieldType->copy(), memoryManager));
    }
}

ListAuxiliaryBuffer::ListAuxiliaryBuffer(const LogicalType& dataVectorType,
    storage::MemoryManager* memoryManager)
    : capacity{DEFAULT_VECTOR_CAPACITY}, size{0},
      dataVector{std::make_shared<ValueVector>(dataVectorType.copy(), memoryManager)} {}

list_entry_t ListAuxiliaryBuffer::addList(list_size_t listSize) {
    auto listEntry = list_entry_t{size, listSize};
    bool needResizeDataVector = size + listSize > capacity;
    while (size + listSize > capacity) {
        capacity *= CHUNK_RESIZE_RATIO;
    }
    if (needResizeDataVector) {
        resizeDataVector(dataVector.get());
    }
    size += listSize;
    return listEntry;
}

void ListAuxiliaryBuffer::resize(uint64_t numValues) {
    if (numValues <= capacity) {
        size = numValues;
        return;
    }
    bool needResizeDataVector = numValues > capacity;
    while (numValues > capacity) {
        capacity *= 2;
        KU_ASSERT(capacity != 0);
    }
    if (needResizeDataVector) {
        resizeDataVector(dataVector.get());
    }
    size = numValues;
}

void ListAuxiliaryBuffer::resizeDataVector(ValueVector* dataVector) {
    const auto newSize = capacity * dataVector->getNumBytesPerValue();
    const auto copySize = size * dataVector->getNumBytesPerValue();
    if (dataVector->memoryManager_) {
        auto newBuffer = dataVector->memoryManager_->allocateBuffer(true /*initializeToZero*/, newSize);
        memcpy(newBuffer->getData(), dataVector->valueBufferPtr_, copySize);
        dataVector->mmBuffer_ = std::move(newBuffer);
        dataVector->valueBuffer.reset();
        dataVector->valueBufferPtr_ = dataVector->mmBuffer_->getData();
    } else {
        auto buffer = std::make_unique<uint8_t[]>(newSize);
        memcpy(buffer.get(), dataVector->valueBufferPtr_, copySize);
        dataVector->valueBuffer = std::move(buffer);
        dataVector->mmBuffer_.reset();
        dataVector->valueBufferPtr_ = dataVector->valueBuffer.get();
    }
    dataVector->nullMask.resize(capacity);
    if (dataVector->dataType.getPhysicalType() == PhysicalTypeID::STRUCT) {
        resizeStructDataVector(dataVector);
    }
}

void ListAuxiliaryBuffer::resizeStructDataVector(ValueVector* dataVector) {
    std::iota(reinterpret_cast<int64_t*>(
                  dataVector->getData() + dataVector->getNumBytesPerValue() * size),
        reinterpret_cast<int64_t*>(
            dataVector->getData() + dataVector->getNumBytesPerValue() * capacity),
        size);
    auto fieldVectors = StructVector::getFieldVectors(dataVector);
    for (auto& fieldVector : fieldVectors) {
        resizeDataVector(fieldVector.get());
    }
}

std::unique_ptr<AuxiliaryBuffer> AuxiliaryBufferFactory::getAuxiliaryBuffer(LogicalType& type,
    storage::MemoryManager* memoryManager) {
    switch (type.getPhysicalType()) {
    case PhysicalTypeID::STRING:
        return std::make_unique<StringAuxiliaryBuffer>(memoryManager);
    case PhysicalTypeID::STRUCT:
        return std::make_unique<StructAuxiliaryBuffer>(type, memoryManager);
    case PhysicalTypeID::LIST:
        return std::make_unique<ListAuxiliaryBuffer>(ListType::getChildType(type), memoryManager);
    case PhysicalTypeID::ARRAY:
        return std::make_unique<ListAuxiliaryBuffer>(ArrayType::getChildType(type), memoryManager);
    default:
        return nullptr;
    }
}

} // namespace common
} // namespace kuzu
