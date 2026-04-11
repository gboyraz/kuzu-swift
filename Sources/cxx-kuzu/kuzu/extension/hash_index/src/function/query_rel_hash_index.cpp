#include "function/hash_index_functions.h"

#include "binder/binder.h"
#include "catalog/catalog.h"
#include "catalog/catalog_entry/rel_group_catalog_entry.h"
#include "common/exception/binder.h"
#include "common/type_utils.h"
#include "common/types/ku_string.h"
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

struct QueryRelHashIndexBindData final : TableFuncBindData {
    table_id_t innerOid;
    std::string indexName;
    std::vector<offset_t> resultOffsets;

    QueryRelHashIndexBindData(binder::expression_vector columns, table_id_t innerOid,
        std::string indexName, std::vector<offset_t> resultOffsets)
        : TableFuncBindData{std::move(columns), resultOffsets.size()},
          innerOid{innerOid}, indexName{std::move(indexName)},
          resultOffsets{std::move(resultOffsets)} {}

    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<QueryRelHashIndexBindData>(
            columns, innerOid, indexName, resultOffsets);
    }
};

static std::unique_ptr<TableFuncBindData> bindFunc(main::ClientContext* context,
    const TableFuncBindInput* input) {
    auto tableName = input->getLiteralVal<std::string>(0);
    auto indexName = input->getLiteralVal<std::string>(1);
    binder::Binder::validateTableExistence(*context, tableName);
    auto tableEntry =
        context->getCatalog()->getTableCatalogEntry(context->getTransaction(), tableName);
    if (tableEntry->getType() != CatalogEntryType::REL_GROUP_ENTRY) {
        throw BinderException(stringFormat("{} is not a REL table.", tableName));
    }
    auto& relGroupEntry = tableEntry->constCast<RelGroupCatalogEntry>();
    auto relGroupID = tableEntry->getTableID();
    auto innerOid = relGroupEntry.getSingleRelEntryInfo().oid;

    if (!context->getCatalog()->containsIndex(
            context->getTransaction(), relGroupID, indexName)) {
        throw BinderException(stringFormat(
            "Table {} doesn't have an index with name {}.", tableName, indexName));
    }
    auto storageManager = context->getStorageManager();
    auto& relTable =
        storageManager->getTable(innerOid)->cast<storage::RelTable>();
    auto indexOpt = relTable.getIndex(indexName);

    // Lazy rebuild: after DB reopen the catalog entry survives but the
    // in-memory index on RelTable does not.  Rebuild now using Cypher
    // (safe because the DB is fully open at query time).
    if (!indexOpt.has_value() && tableEntry->containsProperty(indexName)) {
        auto columnID = tableEntry->getColumnID(indexName);
        auto& propDef = tableEntry->getProperty(indexName);
        auto keyType = propDef.getType().getPhysicalType();
        auto logicalType = propDef.getType().copy();

        auto hashType = SecondaryHashIndex::getIndexType();
        storage::IndexInfo indexInfo{indexName, hashType.typeName, relGroupID,
            {columnID}, {keyType},
            hashType.constraintType == storage::IndexConstraintType::PRIMARY,
            hashType.definitionType == storage::IndexDefinitionType::BUILTIN};
        auto storageInfoPtr =
            std::make_unique<SecondaryHashIndexStorageInfo>(0, columnID);
        auto idx = std::make_unique<SecondaryHashIndex>(
            std::move(indexInfo), std::move(storageInfoPtr));

        // Direct CSR scan — avoids creating a Connection (which would deadlock).
        auto* transaction = context->getTransaction();
        auto* mm = context->getMemoryManager();
        auto directions = relTable.getStorageDirections();
        if (!directions.empty()) {
            auto direction = directions[0];
            auto* tableData = relTable.getDirectedTableData(direction);
            auto numNodeGroups = tableData->getNumNodeGroups();
            auto boundTableID = (direction == RelDataDirection::FWD)
                                    ? relTable.getFromNodeTableID()
                                    : relTable.getToNodeTableID();
            auto relIDVec =
                std::make_unique<ValueVector>(LogicalType::INTERNAL_ID(), mm);
            auto propVec =
                std::make_unique<ValueVector>(logicalType.copy(), mm);
            auto outState = std::make_shared<DataChunkState>();
            relIDVec->setState(outState);
            propVec->setState(outState);
            auto nodeIDVector =
                std::make_unique<ValueVector>(LogicalType::INTERNAL_ID(), mm);
            auto nodeIDState = std::make_shared<DataChunkState>();
            nodeIDVector->setState(nodeIDState);
            auto insertState = idx->initInsertState(context, nullptr);
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
                            nodeID_t{groupStartOffset + batchStart + i,
                                boundTableID});
                    }
                    nodeIDState->getSelVectorUnsafe().setToUnfiltered(batchSize);
                    auto scanState =
                        std::make_unique<storage::RelTableScanState>(*mm,
                            nodeIDVector.get(),
                            std::vector<ValueVector*>{relIDVec.get(),
                                propVec.get()},
                            outState, false);
                    scanState->setToTable(transaction, &relTable,
                        {storage::REL_ID_COLUMN_ID, columnID}, {}, direction);
                    scanState->initState(transaction, nodeGroup);
                    while (scanState->scanNext(transaction)) {
                        auto selSize = outState->getSelVector().getSelSize();
                        if (selSize == 0) continue;
                        std::vector<ValueVector*> vecs{propVec.get()};
                        idx->insert(transaction, *relIDVec, vecs,
                            *insertState);
                    }
                }
            }
        }

        relTable.addIndex(std::move(idx));
        indexOpt = relTable.getIndex(indexName);
    }

    if (!indexOpt.has_value()) {
        throw BinderException(
            stringFormat("Index {} not found on table {}.", indexName, tableName));
    }
    auto* index = &indexOpt.value()->cast<SecondaryHashIndex>();

    std::vector<offset_t> resultOffsets;
    auto lookupValue = input->getLiteralVal<std::string>(2);
    auto keyType = index->getIndexInfo().keyDataTypes[0];
    TypeUtils::visit(
        keyType,
        [&](ku_string_t) {
            ku_string_t kuStr(lookupValue.data(), lookupValue.size());
            index->lookup(reinterpret_cast<const uint8_t*>(&kuStr), resultOffsets);
        },
        [&](int64_t) {
            auto val = std::stoll(lookupValue);
            index->lookup(reinterpret_cast<const uint8_t*>(&val), resultOffsets);
        },
        [&](int32_t) {
            auto val = static_cast<int32_t>(std::stoi(lookupValue));
            index->lookup(reinterpret_cast<const uint8_t*>(&val), resultOffsets);
        },
        [&](double) {
            auto val = std::stod(lookupValue);
            index->lookup(reinterpret_cast<const uint8_t*>(&val), resultOffsets);
        },
        [&](float) {
            auto val = std::stof(lookupValue);
            index->lookup(reinterpret_cast<const uint8_t*>(&val), resultOffsets);
        },
        [&](auto) {
            throw BinderException("Unsupported key type for rel hash index query.");
        });

    std::vector<std::string> columnNames = {"rel_id"};
    std::vector<LogicalType> columnTypes;
    columnTypes.push_back(LogicalType::INTERNAL_ID());
    columnNames =
        TableFunction::extractYieldVariables(columnNames, input->yieldVariables);
    auto columns = input->binder->createVariables(columnNames, columnTypes);
    return std::make_unique<QueryRelHashIndexBindData>(
        std::move(columns), innerOid, indexName, std::move(resultOffsets));
}

static offset_t internalTableFunc(const TableFuncMorsel& morsel,
    const TableFuncInput& input, DataChunk& output) {
    auto& bindData = *input.bindData->constPtrCast<QueryRelHashIndexBindData>();
    auto& relIDVector = output.getValueVectorMutable(0);
    auto numToOutput = morsel.endOffset - morsel.startOffset;
    for (auto i = 0u; i < numToOutput; i++) {
        auto pos = output.state->getSelVector()[i];
        relIDVector.setValue(pos,
            internalID_t{bindData.resultOffsets[morsel.startOffset + i],
                bindData.innerOid});
    }
    return numToOutput;
}

function_set QueryRelHashIndexFunction::getFunctionSet() {
    function_set functionSet;
    auto func = std::make_unique<TableFunction>(name,
        std::vector{LogicalTypeID::STRING, LogicalTypeID::STRING,
            LogicalTypeID::STRING});
    func->tableFunc = SimpleTableFunc::getTableFunc(internalTableFunc);
    func->bindFunc = bindFunc;
    func->initSharedStateFunc = SimpleTableFunc::initSharedState;
    func->initLocalStateFunc = TableFunction::initEmptyLocalState;
    func->canParallelFunc = [] { return false; };
    functionSet.push_back(std::move(func));
    return functionSet;
}

} // namespace hash_index_extension
} // namespace kuzu

