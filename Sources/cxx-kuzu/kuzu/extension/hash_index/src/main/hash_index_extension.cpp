#include "main/hash_index_extension.h"

#include "catalog/catalog.h"
#include "catalog/catalog_entry/index_catalog_entry.h"
#include "catalog/catalog_entry/table_catalog_entry.h"
#include "extension/extension.h"
#include "function/hash_index_functions.h"
#include "index/secondary_hash_index.h"
#include "main/client_context.h"
#include "main/database.h"
#include "storage/storage_manager.h"
#include "storage/table/node_table.h"

namespace kuzu {
namespace hash_index_extension {

// Helper to split comma-separated string and trim whitespace.
static std::vector<std::string> splitProperties(const std::string& props) {
    std::vector<std::string> result;
    size_t start = 0;
    for (size_t i = 0; i <= props.size(); i++) {
        if (i == props.size() || props[i] == ',') {
            auto part = props.substr(start, i - start);
            auto first = part.find_first_not_of(" \t");
            auto last = part.find_last_not_of(" \t");
            if (first != std::string::npos) {
                result.push_back(part.substr(first, last - first + 1));
            }
            start = i + 1;
        }
    }
    return result;
}

// Rebuild a secondary hash index from scratch by scanning all committed data.
// This is used during WAL recovery when the catalog knows about the index but
// NodeTable has no IndexHolder (because WAL replay only restores catalog entries).
static void rebuildIndex(main::ClientContext* context, storage::StorageManager* storageManager,
    catalog::IndexCatalogEntry* indexEntry, bool isUniqueIdx = false) {
    auto* catalog = context->getCatalog();
    auto* transaction = context->getTransaction();
    auto tableID = indexEntry->getTableID();
    auto& nodeTable = storageManager->getTable(tableID)->cast<storage::NodeTable>();

    auto* tableEntry = catalog->getTableCatalogEntry(transaction, tableID);
    auto indexName = indexEntry->getIndexName();
    auto propNames = splitProperties(indexName);
    auto hashType = isUniqueIdx ? SecondaryHashIndex::getUniqueIndexType()
                                : SecondaryHashIndex::getIndexType();

    if (propNames.size() > 1) {
        // === Composite index ===
        std::vector<common::column_id_t> colIDs;
        std::vector<common::LogicalType> logTypes;
        for (auto& pn : propNames) {
            if (!tableEntry->containsProperty(pn)) return;
            colIDs.push_back(tableEntry->getColumnID(pn));
            logTypes.push_back(tableEntry->getProperty(pn).getType().copy());
        }
        std::vector<common::PhysicalTypeID> keyTypes{common::PhysicalTypeID::STRING};
        storage::IndexInfo indexInfo{indexName, hashType.typeName, tableID,
            colIDs, keyTypes,
            hashType.constraintType == storage::IndexConstraintType::PRIMARY,
            hashType.definitionType == storage::IndexDefinitionType::BUILTIN};

        auto storageInfoPtr = std::make_unique<SecondaryHashIndexStorageInfo>(
            0, colIDs, propNames, isUniqueIdx);
        auto index = std::make_unique<SecondaryHashIndex>(
            std::move(indexInfo), std::move(storageInfoPtr));

        auto numNodeGroups = nodeTable.getNumCommittedNodeGroups();
        if (numNodeGroups > 0) {
            std::vector<common::LogicalType> types;
            for (auto& lt : logTypes) types.push_back(lt.copy());
            auto dataChunk = storage::Table::constructDataChunk(
                context->getMemoryManager(), std::move(types));
            std::vector<common::ValueVector*> outVectors;
            for (uint32_t c = 0; c < colIDs.size(); c++) {
                outVectors.push_back(&dataChunk.getValueVectorMutable(c));
            }
            auto nodeIDVector = std::make_unique<common::ValueVector>(
                common::LogicalType::INTERNAL_ID(), context->getMemoryManager());
            nodeIDVector->setState(dataChunk.state);

            auto scanState = std::make_unique<storage::NodeTableScanState>(
                nodeIDVector.get(), outVectors, dataChunk.state);
            scanState->setToTable(transaction, &nodeTable, colIDs, {});

            auto insertState = index->initInsertState(context, nullptr);

            for (common::node_group_idx_t ng = 0; ng < numNodeGroups; ng++) {
                scanState->source = storage::TableScanSource::COMMITTED;
                scanState->nodeGroupIdx = ng;
                nodeTable.initScanState(transaction, *scanState);
                while (nodeTable.scan(transaction, *scanState)) {
                    if (dataChunk.state->getSelSize() == 0) continue;
                    index->insert(transaction, *nodeIDVector, outVectors, *insertState);
                }
            }
        }
        nodeTable.addIndex(std::move(index));
    } else {
        // === Single property index ===
        auto& propertyName = propNames[0];
        if (!tableEntry->containsProperty(propertyName)) return;
        auto columnID = tableEntry->getColumnID(propertyName);
        auto keyType = tableEntry->getProperty(propertyName).getType().getPhysicalType();
        auto logicalType = tableEntry->getProperty(propertyName).getType().copy();

        storage::IndexInfo indexInfo{propertyName, hashType.typeName, tableID,
            {columnID}, {keyType},
            hashType.constraintType == storage::IndexConstraintType::PRIMARY,
            hashType.definitionType == storage::IndexDefinitionType::BUILTIN};

        auto storageInfoPtr = std::make_unique<SecondaryHashIndexStorageInfo>(0, columnID, isUniqueIdx);
        auto index = std::make_unique<SecondaryHashIndex>(
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
}

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
        auto indexType = indexEntry->getIndexType();
        if (indexType != "HASH" && indexType != "UNIQUE_HASH") {
            continue;
        }
        bool isUniqueIdx = (indexType == "UNIQUE_HASH");
        if (!indexEntry->isLoaded()) {
            indexEntry->setAuxInfo(std::make_unique<HashIndexAuxInfo>(isUniqueIdx));
        }
        auto& nodeTable =
            storageManager->getTable(indexEntry->getTableID())->cast<storage::NodeTable>();
        auto optionalIndex = nodeTable.getIndexHolder(indexEntry->getIndexName());
        if (optionalIndex.has_value()) {
            if (!optionalIndex.value().get().isLoaded()) {
                optionalIndex.value().get().load(context, storageManager);
            }
        } else {
            rebuildIndex(context, storageManager, indexEntry, isUniqueIdx);
        }
    }
}

void HashIndexExtension::load(main::ClientContext* context) {
    auto& db = *context->getDatabase();
    extension::ExtensionUtils::addStandaloneTableFunc<CreateHashIndexFunction>(db);
    extension::ExtensionUtils::addStandaloneTableFunc<DropHashIndexFunction>(db);
    extension::ExtensionUtils::addTableFunc<QueryHashIndexFunction>(db);
    extension::ExtensionUtils::addTableFunc<ListHashIndexesFunction>(db);
    extension::ExtensionUtils::addStandaloneTableFunc<CreateUniqueIndexFunction>(db);
    extension::ExtensionUtils::addStandaloneTableFunc<DropUniqueIndexFunction>(db);
    extension::ExtensionUtils::addTableFunc<QueryUniqueIndexFunction>(db);
    extension::ExtensionUtils::addTableFunc<ListUniqueIndexesFunction>(db);
    extension::ExtensionUtils::registerIndexType(db, SecondaryHashIndex::getIndexType());
    extension::ExtensionUtils::registerIndexType(db, SecondaryHashIndex::getUniqueIndexType());
    initHashIndexEntries(context);
}

void HashIndexExtension::reconcileIndexes(main::ClientContext* context) {
    initHashIndexEntries(context);
}

} // namespace hash_index_extension
} // namespace kuzu

