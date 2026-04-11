#include "storage/buffer_manager/memory_manager.h"

#include <mutex>

#include "common/exception/buffer_manager.h"
#include "common/file_system/virtual_file_system.h"
#include "common/types/types.h"
#include "storage/buffer_manager/buffer_manager.h"
#include "storage/buffer_manager/spiller.h"
#include "storage/file_handle.h"

using namespace kuzu::common;

namespace kuzu {
namespace storage {

MemoryBuffer::MemoryBuffer(MemoryManager* mm, page_idx_t pageIdx, uint8_t* buffer, uint64_t size)
    : buffer{buffer, static_cast<size_t>(size)}, mm{mm}, pageIdx{pageIdx}, evicted{false} {}

MemoryBuffer::~MemoryBuffer() {
    if (buffer.data() != nullptr && !evicted) {
        mm->freeBlock(pageIdx, buffer);
        mm->updateUsedMemoryForFreedBlock(pageIdx, buffer);
        buffer = std::span<uint8_t>();
    }
}

SpillResult MemoryBuffer::setSpilledToDisk(uint64_t filePosition) {
    auto bufferSize = buffer.size();
    mm->freeBlock(pageIdx, buffer);
    // Track MM deallocation for unified budget when spilling malloc'd buffers.
    mm->updateUsedMemoryForFreedBlock(pageIdx, buffer);
    // reinterpret_cast isn't allowed here, but we shouldn't leave the invalid pointer and
    // still want to store the size
    buffer = std::span(static_cast<uint8_t*>(nullptr), buffer.size());
    evicted = true;
    this->filePosition = filePosition;
    if (pageIdx == INVALID_PAGE_IDX) {
        return SpillResult{buffer.size(), 0};
    } else {
        return SpillResult{0, buffer.size()};
    }
}

void MemoryBuffer::prepareLoadFromDisk() {
    KU_ASSERT(buffer.data() == nullptr && evicted);
    buffer = mm->mallocBuffer(false, buffer.size());
    evicted = false;
}

MemoryManager::MemoryManager(BufferManager* bm, VirtualFileSystem* vfs) : bm{bm} {
    pageSize = TEMP_PAGE_SIZE;
    fh = bm->getFileHandle("mm-256KB", FileHandle::O_IN_MEM_TEMP_FILE, vfs, nullptr);
}

std::span<uint8_t> MemoryManager::mallocBuffer(bool initializeToZero, uint64_t size) {
    // Use unified budget: reserveForMemoryManager tracks MM usage separately
    // and enforces headroom so BM always has space for page cache operations.
    if (!bm->reserveForMemoryManager(size)) {
        throw BufferManagerException(
            "Unable to allocate memory! The buffer pool is full and no memory could be freed!");
    }
    void* buffer = nullptr;
    bm->nonEvictableMemory += size;
    if (initializeToZero) {
        buffer = calloc(size, 1);
    } else {
        buffer = malloc(size);
    }
    return std::span(static_cast<uint8_t*>(buffer), size);
}

std::unique_ptr<MemoryBuffer> MemoryManager::allocateBuffer(bool initializeToZero, uint64_t size) {
    // All MM allocations use mallocBuffer() which goes through reserveForMemoryManager().
    // This ensures the Spiller is never triggered from MM allocations — MemoryBuffers must
    // never be evicted/spilled. The previous TEMP_PAGE_SIZE path used pin() → reserve()
    // which could trigger spiller->claimNextGroup(), bypassing this protection.
    auto buffer = mallocBuffer(initializeToZero, size);
    return std::make_unique<MemoryBuffer>(this, INVALID_PAGE_IDX, buffer.data(), size);
}

void MemoryManager::freeBlock(page_idx_t pageIdx, std::span<uint8_t> buffer) {
    if (pageIdx == INVALID_PAGE_IDX) {
        std::free(buffer.data());
    } else {
        bm->unpin(*fh, pageIdx);
    }
}

void MemoryManager::updateUsedMemoryForFreedBlock(page_idx_t pageIdx, std::span<uint8_t> buffer) {
    if (pageIdx == INVALID_PAGE_IDX) {
        // Unified budget: track MM deallocation separately.
        bm->freeForMemoryManager(buffer.size());
        bm->freeUsedMemory(buffer.size());
        bm->nonEvictableMemory -= buffer.size();
    } else {
        std::unique_lock<std::mutex> lock(allocatorLock);
        freePages.push(pageIdx);
    }
}

} // namespace storage
} // namespace kuzu
