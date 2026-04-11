#include "main/range_index_extension.h"

#include "catalog/catalog.h"
#include "catalog/catalog_entry/index_catalog_entry.h"
#include "catalog/catalog_entry/table_catalog_entry.h"
#include "extension/extension.h"
#include "function/range_index_functions.h"
#include "index/secondary_range_index.h"
#include "main/client_context.h"
#include "main/database.h"
#include "storage/storage_manager.h"
#include "storage/table/node_table.h"

namespace kuzu {
namespace range_index_extension {

// Rebuild a secondary range index from scratch by scanning all committed data.
static void rebuildIndex(main::ClientContext* context, storage::StorageManager* storageManager,
    catalog::IndexCatalogEntry* indexEntry) {
    auto* catalog = context->getCatalog();
    auto* transaction = context->getTransaction();
    auto tableID = indexEntry->getTableID();
    auto& nodeTable = storageManager->getTable(tableID)->cast<storage::NodeTable>();

    auto* tableEntry = catalog->getTableCatalogEntry(transaction, tableID);
    auto propertyName = indexEntry->getIndexName();
    auto rangeType = SecondaryRangeIndex::getIndexType();

    if (!tableEntry->containsProperty(propertyName)) return;
    auto columnID = tableEntry->getColumnID(propertyName);
    auto keyType = tableEntry->getProperty(propertyName).getType().getPhysicalType();
    auto logicalType = tableEntry->getProperty(propertyName).getType().copy();

    storage::IndexInfo indexInfo{propertyName, rangeType.typeName, tableID,
        {columnID}, {keyType},
        rangeType.constraintType == storage::IndexConstraintType::PRIMARY,
        rangeType.definitionType == storage::IndexDefinitionType::BUILTIN};

    auto storageInfoPtr = std::make_unique<SecondaryRangeIndexStorageInfo>(0, columnID);
    auto index = std::make_unique<SecondaryRangeIndex>(
        std::move(indexInfo), std::move(storageInfoPtr));

    auto numNodeGroups = nodeTable.getNumCommittedNodeGroups();
    if (numNodeGroups > 0) {
        std::vector<common::LogicalType> types;
        types.push_back(logicalType.copy());
        auto dataChunk = storage::Table::constructDataChunk(
            context->getMemoryManager(), std::move(types));
        auto* propVector = &dataChunk.getValueVectorMutable(0);
        auto nodeIDVector = std::make_unique<common::ValueVector>(
            common::LogicalType::INTERNAL_ID(), context->getMemoryManager());
        nodeIDVector->setState(dataChunk.state);

        std::vector<common::ValueVector*> outVectors{propVector};
        auto scanState = std::make_unique<storage::NodeTableScanState>(
            nodeIDVector.get(), outVectors, dataChunk.state);
        scanState->setToTable(transaction, &nodeTable, {columnID}, {});

        auto insertState = index->initInsertState(context, nullptr);

        for (common::node_group_idx_t ng = 0; ng < numNodeGroups; ng++) {
            scanState->source = storage::TableScanSource::COMMITTED;
            scanState->nodeGroupIdx = ng;
            nodeTable.initScanState(transaction, *scanState);
            while (nodeTable.scan(transaction, *scanState)) {
                if (dataChunk.state->getSelSize() == 0) continue;
                std::vector<common::ValueVector*> indexVectors{propVector};
                index->insert(transaction, *nodeIDVector, indexVectors, *insertState);
            }
        }
    }
    nodeTable.addIndex(std::move(index));
}

static void initRangeIndexEntries(main::ClientContext* context) {
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
        if (indexEntry->getIndexType() != "RANGE") {
            continue;
        }
        if (!indexEntry->isLoaded()) {
            indexEntry->setAuxInfo(std::make_unique<RangeIndexAuxInfo>());
        }
        auto& nodeTable =
            storageManager->getTable(indexEntry->getTableID())->cast<storage::NodeTable>();
        auto optionalIndex = nodeTable.getIndexHolder(indexEntry->getIndexName());
        if (optionalIndex.has_value()) {
            if (!optionalIndex.value().get().isLoaded()) {
                optionalIndex.value().get().load(context, storageManager);
            }
        } else {
            rebuildIndex(context, storageManager, indexEntry);
        }
    }
}

void RangeIndexExtension::load(main::ClientContext* context) {
    auto& db = *context->getDatabase();
    extension::ExtensionUtils::addStandaloneTableFunc<CreateRangeIndexFunction>(db);
    extension::ExtensionUtils::addStandaloneTableFunc<DropRangeIndexFunction>(db);
    extension::ExtensionUtils::addTableFunc<QueryRangeIndexFunction>(db);
    extension::ExtensionUtils::addTableFunc<ListRangeIndexesFunction>(db);
    extension::ExtensionUtils::registerIndexType(db, SecondaryRangeIndex::getIndexType());
    initRangeIndexEntries(context);
}

void RangeIndexExtension::reconcileIndexes(main::ClientContext* context) {
    initRangeIndexEntries(context);
}

} // namespace range_index_extension
} // namespace kuzu

