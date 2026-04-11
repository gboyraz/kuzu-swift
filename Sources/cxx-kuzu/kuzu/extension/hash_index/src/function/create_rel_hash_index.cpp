#include "function/hash_index_functions.h"

#include "binder/binder.h"
#include "catalog/catalog.h"
#include "catalog/catalog_entry/index_catalog_entry.h"
#include "catalog/catalog_entry/rel_group_catalog_entry.h"
#include "common/exception/binder.h"
#include "common/exception/runtime.h"
#include "function/table/bind_data.h"
#include "function/table/simple_table_function.h"
#include "index/secondary_hash_index.h"
#include "main/client_context.h"
#include "main/database.h"
#include "processor/execution_context.h"
#include "storage/storage_manager.h"
#include "storage/storage_utils.h"
#include "storage/table/rel_table.h"

using namespace kuzu::common;
using namespace kuzu::function;
using namespace kuzu::catalog;

namespace kuzu {
namespace hash_index_extension {

struct CreateRelHashIndexBindData final : TableFuncBindData {
    std::string tableName;
    table_id_t relGroupID;
    table_id_t innerOid;
    std::string propertyName;
    column_id_t columnID;
    PhysicalTypeID keyType;
    LogicalType logicalType;

    CreateRelHashIndexBindData(std::string tableName, table_id_t relGroupID,
        table_id_t innerOid, std::string propertyName, column_id_t columnID,
        PhysicalTypeID keyType, LogicalType logicalType)
        : TableFuncBindData{1}, tableName{std::move(tableName)},
          relGroupID{relGroupID}, innerOid{innerOid},
          propertyName{std::move(propertyName)}, columnID{columnID},
          keyType{keyType}, logicalType{std::move(logicalType)} {}

    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<CreateRelHashIndexBindData>(
            tableName, relGroupID, innerOid, propertyName, columnID, keyType,
            logicalType.copy());
    }
};

static std::unique_ptr<TableFuncBindData> bindFunc(main::ClientContext* context,
    const TableFuncBindInput* input) {
    if (!context->getTransactionContext()->isAutoTransaction()) {
        throw BinderException(
            "CREATE_REL_HASH_INDEX is only supported in auto transaction mode.");
    }
    auto tableName = input->getLiteralVal<std::string>(0);
    auto propertyName = input->getLiteralVal<std::string>(1);
    binder::Binder::validateTableExistence(*context, tableName);
    auto tableEntry =
        context->getCatalog()->getTableCatalogEntry(context->getTransaction(), tableName);
    if (tableEntry->getType() != CatalogEntryType::REL_GROUP_ENTRY) {
        throw BinderException(stringFormat("{} is not a REL table.", tableName));
    }
    auto& relGroupEntry = tableEntry->constCast<RelGroupCatalogEntry>();
    auto relGroupID = tableEntry->getTableID();
    auto innerOid = relGroupEntry.getSingleRelEntryInfo().oid;

    binder::Binder::validateColumnExistence(tableEntry, propertyName);
    auto columnID = tableEntry->getColumnID(propertyName);
    auto& propDef = tableEntry->getProperty(propertyName);
    auto keyType = propDef.getType().getPhysicalType();
    if (context->getCatalog()->containsIndex(
            context->getTransaction(), relGroupID, propertyName)) {
        throw BinderException(stringFormat(
            "Index {} already exists on table {}.", propertyName, tableName));
    }
    return std::make_unique<CreateRelHashIndexBindData>(
        tableName, relGroupID, innerOid, propertyName, columnID, keyType,
        propDef.getType().copy());
}

static offset_t tableFunc(const TableFuncInput& input, TableFuncOutput&) {
    auto& bindData = *input.bindData->constPtrCast<CreateRelHashIndexBindData>();
    auto clientContext = input.context->clientContext;
    auto transaction = clientContext->getTransaction();
    auto catalog = clientContext->getCatalog();
    auto storageManager = clientContext->getStorageManager();
    auto& relTable =
        storageManager->getTable(bindData.innerOid)->cast<storage::RelTable>();

    auto hashType = SecondaryHashIndex::getIndexType();
    storage::IndexInfo indexInfo{bindData.propertyName, hashType.typeName,
        bindData.relGroupID, {bindData.columnID}, {bindData.keyType},
        hashType.constraintType == storage::IndexConstraintType::PRIMARY,
        hashType.definitionType == storage::IndexDefinitionType::BUILTIN};

    auto storageInfoPtr =
        std::make_unique<SecondaryHashIndexStorageInfo>(0, bindData.columnID);
    auto index = std::make_unique<SecondaryHashIndex>(
        std::move(indexInfo), std::move(storageInfoPtr));

    // Direct CSR scan — avoids creating a Connection (which would deadlock).
    auto* mm = clientContext->getMemoryManager();
    auto directions = relTable.getStorageDirections();
    if (!directions.empty()) {
        auto direction = directions[0];
        auto* tableData = relTable.getDirectedTableData(direction);
        auto numNodeGroups = tableData->getNumNodeGroups();
        auto boundTableID = (direction == RelDataDirection::FWD)
                                ? relTable.getFromNodeTableID()
                                : relTable.getToNodeTableID();
        auto relIDVector =
            std::make_unique<ValueVector>(LogicalType::INTERNAL_ID(), mm);
        auto propVector =
            std::make_unique<ValueVector>(bindData.logicalType.copy(), mm);
        auto outState = std::make_shared<DataChunkState>();
        relIDVector->setState(outState);
        propVector->setState(outState);
        auto nodeIDVector =
            std::make_unique<ValueVector>(LogicalType::INTERNAL_ID(), mm);
        auto nodeIDState = std::make_shared<DataChunkState>();
        nodeIDVector->setState(nodeIDState);
        auto insertState = index->initInsertState(clientContext, nullptr);
        for (node_group_idx_t ng = 0; ng < numNodeGroups; ng++) {
            auto* nodeGroup = tableData->getNodeGroup(ng);
            if (!nodeGroup) continue;
            auto groupStartOffset =
                storage::StorageUtils::getStartOffsetOfNodeGroup(ng);
            for (uint64_t batchStart = 0;
                 batchStart < StorageConfig::NODE_GROUP_SIZE;
                 batchStart += DEFAULT_VECTOR_CAPACITY) {
                auto batchSize = std::min(DEFAULT_VECTOR_CAPACITY,
                    StorageConfig::NODE_GROUP_SIZE - batchStart);
                for (uint64_t i = 0; i < batchSize; i++) {
                    nodeIDVector->setValue<nodeID_t>(i,
                        nodeID_t{groupStartOffset + batchStart + i, boundTableID});
                }
                nodeIDState->getSelVectorUnsafe().setToUnfiltered(batchSize);
                auto scanState = std::make_unique<storage::RelTableScanState>(*mm,
                    nodeIDVector.get(),
                    std::vector<ValueVector*>{relIDVector.get(), propVector.get()},
                    outState, false);
                scanState->setToTable(transaction, &relTable,
                    {storage::REL_ID_COLUMN_ID, bindData.columnID}, {}, direction);
                scanState->initState(transaction, nodeGroup);
                while (scanState->scanNext(transaction)) {
                    auto selSize = outState->getSelVector().getSelSize();
                    if (selSize == 0) continue;
                    std::vector<ValueVector*> indexVectors{propVector.get()};
                    index->insert(transaction, *relIDVector, indexVectors,
                        *insertState);
                }
            }
        }
    }

    auto indexEntry = std::make_unique<IndexCatalogEntry>(
        hashType.typeName, bindData.relGroupID, bindData.propertyName,
        std::vector<property_id_t>{}, std::make_unique<HashIndexAuxInfo>());
    catalog->createIndex(transaction, std::move(indexEntry));
    relTable.addIndex(std::move(index));
    return 0;
}

function_set CreateRelHashIndexFunction::getFunctionSet() {
    function_set functionSet;
    auto func = std::make_unique<TableFunction>(name,
        std::vector{LogicalTypeID::STRING, LogicalTypeID::STRING});
    func->tableFunc = tableFunc;
    func->bindFunc = bindFunc;
    func->initSharedStateFunc = SimpleTableFunc::initSharedState;
    func->initLocalStateFunc = TableFunction::initEmptyLocalState;
    func->canParallelFunc = [] { return false; };
    func->isReadOnly = false;
    functionSet.push_back(std::move(func));
    return functionSet;
}

} // namespace hash_index_extension
} // namespace kuzu

