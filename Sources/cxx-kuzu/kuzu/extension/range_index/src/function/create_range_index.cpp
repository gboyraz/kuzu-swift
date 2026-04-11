#include "function/range_index_functions.h"

#include "binder/binder.h"
#include "catalog/catalog.h"
#include "catalog/catalog_entry/index_catalog_entry.h"
#include "catalog/catalog_entry/node_table_catalog_entry.h"
#include "common/exception/binder.h"
#include "common/type_utils.h"
#include "common/types/ku_string.h"
#include "function/table/bind_data.h"
#include "function/table/simple_table_function.h"
#include "index/secondary_range_index.h"
#include "main/client_context.h"
#include "processor/execution_context.h"
#include "storage/storage_manager.h"
#include "storage/table/node_table.h"

using namespace kuzu::common;
using namespace kuzu::function;
using namespace kuzu::catalog;

namespace kuzu {
namespace range_index_extension {

struct CreateRangeIndexBindData final : TableFuncBindData {
    std::string tableName;
    table_id_t tableID;
    std::string propertyName;
    column_id_t columnID;
    PhysicalTypeID keyType;
    LogicalType logicalType;

    CreateRangeIndexBindData(std::string tableName, table_id_t tableID, std::string propertyName,
        column_id_t columnID, PhysicalTypeID keyType, LogicalType logicalType)
        : TableFuncBindData{1}, tableName{std::move(tableName)},
          tableID{tableID}, propertyName{std::move(propertyName)}, columnID{columnID},
          keyType{keyType}, logicalType{std::move(logicalType)} {}

    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<CreateRangeIndexBindData>(
            tableName, tableID, propertyName, columnID, keyType, logicalType.copy());
    }
};

static void validateKeyType(PhysicalTypeID type) {
    switch (type) {
    case PhysicalTypeID::INT8:
    case PhysicalTypeID::INT16:
    case PhysicalTypeID::INT32:
    case PhysicalTypeID::INT64:
    case PhysicalTypeID::INT128:
    case PhysicalTypeID::UINT8:
    case PhysicalTypeID::UINT16:
    case PhysicalTypeID::UINT32:
    case PhysicalTypeID::UINT64:
    case PhysicalTypeID::FLOAT:
    case PhysicalTypeID::DOUBLE:
    case PhysicalTypeID::STRING:
        return;
    default:
        throw BinderException(
            stringFormat("Range index does not support type {}.", PhysicalTypeUtils::toString(type)));
    }
}

static std::unique_ptr<TableFuncBindData> bindFunc(main::ClientContext* context,
    const TableFuncBindInput* input) {
    if (!context->getTransactionContext()->isAutoTransaction()) {
        throw BinderException("CREATE_RANGE_INDEX is only supported in auto transaction mode.");
    }
    auto tableName = input->getLiteralVal<std::string>(0);
    auto propertyName = input->getLiteralVal<std::string>(1);
    binder::Binder::validateTableExistence(*context, tableName);
    auto tableEntry =
        context->getCatalog()->getTableCatalogEntry(context->getTransaction(), tableName);
    binder::Binder::validateNodeTableType(tableEntry);
    binder::Binder::validateColumnExistence(tableEntry, propertyName);
    auto columnID = tableEntry->getColumnID(propertyName);
    auto& propDef = tableEntry->getProperty(propertyName);
    auto keyType = propDef.getType().getPhysicalType();
    validateKeyType(keyType);
    if (context->getCatalog()->containsIndex(
            context->getTransaction(), tableEntry->getTableID(), propertyName)) {
        throw BinderException(stringFormat(
            "Index {} already exists on table {}.", propertyName, tableName));
    }
    auto logicalType = propDef.getType().copy();
    return std::make_unique<CreateRangeIndexBindData>(
        tableName, tableEntry->getTableID(), propertyName, columnID, keyType,
        std::move(logicalType));
}

static offset_t tableFunc(const TableFuncInput& input, TableFuncOutput&) {
    auto& bindData = *input.bindData->constPtrCast<CreateRangeIndexBindData>();
    auto clientContext = input.context->clientContext;
    auto transaction = clientContext->getTransaction();
    auto catalog = clientContext->getCatalog();
    auto storageManager = clientContext->getStorageManager();
    auto& nodeTable =
        storageManager->getTable(bindData.tableID)->cast<storage::NodeTable>();

    auto rangeType = SecondaryRangeIndex::getIndexType();
    storage::IndexInfo indexInfo{bindData.propertyName, rangeType.typeName, bindData.tableID,
        {bindData.columnID}, {bindData.keyType},
        rangeType.constraintType == storage::IndexConstraintType::PRIMARY,
        rangeType.definitionType == storage::IndexDefinitionType::BUILTIN};

    auto storageInfoPtr = std::make_unique<SecondaryRangeIndexStorageInfo>(0, bindData.columnID);
    auto index = std::make_unique<SecondaryRangeIndex>(
        std::move(indexInfo), std::move(storageInfoPtr));

    auto numNodeGroups = nodeTable.getNumCommittedNodeGroups();
    if (numNodeGroups > 0) {
        std::vector<LogicalType> types;
        types.push_back(bindData.logicalType.copy());
        auto dataChunk = storage::Table::constructDataChunk(
            clientContext->getMemoryManager(), std::move(types));
        auto* propVector = &dataChunk.getValueVectorMutable(0);
        auto nodeIDVector = std::make_unique<ValueVector>(
            LogicalType::INTERNAL_ID(), clientContext->getMemoryManager());
        nodeIDVector->setState(dataChunk.state);

        std::vector<ValueVector*> outVectors{propVector};
        auto scanState = std::make_unique<storage::NodeTableScanState>(
            nodeIDVector.get(), outVectors, dataChunk.state);
        scanState->setToTable(transaction, &nodeTable, {bindData.columnID}, {});

        auto insertState = index->initInsertState(clientContext, nullptr);
        for (node_group_idx_t ng = 0; ng < numNodeGroups; ng++) {
            scanState->source = storage::TableScanSource::COMMITTED;
            scanState->nodeGroupIdx = ng;
            nodeTable.initScanState(transaction, *scanState);
            while (nodeTable.scan(transaction, *scanState)) {
                if (dataChunk.state->getSelSize() == 0) continue;
                std::vector<ValueVector*> indexVectors{propVector};
                index->insert(transaction, *nodeIDVector, indexVectors, *insertState);
            }
        }
    }

    auto indexEntry = std::make_unique<IndexCatalogEntry>(
        rangeType.typeName, bindData.tableID, bindData.propertyName,
        std::vector<property_id_t>{}, std::make_unique<RangeIndexAuxInfo>());
    catalog->createIndex(transaction, std::move(indexEntry));
    nodeTable.addIndex(std::move(index));
    return 0;
}

function_set CreateRangeIndexFunction::getFunctionSet() {
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

} // namespace range_index_extension
} // namespace kuzu

