#include "main/hash_index_extension.h"

#include "catalog/catalog.h"
#include "catalog/catalog_entry/index_catalog_entry.h"
#include "extension/extension.h"
#include "function/hash_index_functions.h"
#include "index/secondary_hash_index.h"
#include "main/database.h"
#include "storage/storage_manager.h"
#include "storage/table/node_table.h"

namespace kuzu {
namespace hash_index_extension {

static void initHashIndexEntries(main::ClientContext* context) {
    auto* storageManager = context->getStorageManager();
    if (!storageManager) {
        return;
    }
    auto* catalog = context->getCatalog();
    if (!catalog) {
        return;
    }
    auto* transaction = context->getTransaction();
    if (!transaction) {
        return;
    }
    for (auto& indexEntry : catalog->getIndexEntries(transaction)) {
        if (indexEntry->getIndexType() == "HASH" && !indexEntry->isLoaded()) {
            // Set auxInfo so the catalog entry is marked as loaded.
            indexEntry->setAuxInfo(std::make_unique<HashIndexAuxInfo>());
            auto& nodeTable =
                storageManager->getTable(indexEntry->getTableID())->cast<storage::NodeTable>();
            auto optionalIndex = nodeTable.getIndexHolder(indexEntry->getIndexName());
            if (optionalIndex.has_value() && !optionalIndex.value().get().isLoaded()) {
                optionalIndex.value().get().load(context, storageManager);
            }
        }
    }
}

void HashIndexExtension::load(main::ClientContext* context) {
    auto& db = *context->getDatabase();
    extension::ExtensionUtils::addStandaloneTableFunc<CreateHashIndexFunction>(db);
    extension::ExtensionUtils::addStandaloneTableFunc<DropHashIndexFunction>(db);
    extension::ExtensionUtils::addTableFunc<QueryHashIndexFunction>(db);
    extension::ExtensionUtils::addTableFunc<ListHashIndexesFunction>(db);
    extension::ExtensionUtils::registerIndexType(db, SecondaryHashIndex::getIndexType());
    initHashIndexEntries(context);
}

} // namespace hash_index_extension
} // namespace kuzu

