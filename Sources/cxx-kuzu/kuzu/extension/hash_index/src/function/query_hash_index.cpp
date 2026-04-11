#include "function/hash_index_functions.h"

#include "binder/binder.h"
#include "catalog/catalog.h"
#include "catalog/catalog_entry/node_table_catalog_entry.h"
#include "common/exception/binder.h"
#include "common/type_utils.h"
#include "common/types/ku_string.h"
#include "function/table/bind_data.h"
#include "function/table/simple_table_function.h"
#include "index/secondary_hash_index.h"
#include "main/client_context.h"
#include "processor/execution_context.h"
#include "storage/storage_manager.h"
#include "storage/table/node_table.h"

using namespace kuzu::common;
using namespace kuzu::function;
using namespace kuzu::catalog;

namespace kuzu {
namespace hash_index_extension {

struct QueryHashIndexBindData final : TableFuncBindData {
    table_id_t tableID;
    std::string indexName;
    std::vector<offset_t> resultOffsets;

    QueryHashIndexBindData(binder::expression_vector columns, table_id_t tableID,
        std::string indexName, std::vector<offset_t> resultOffsets)
        : TableFuncBindData{std::move(columns), resultOffsets.size()},
          tableID{tableID}, indexName{std::move(indexName)},
          resultOffsets{std::move(resultOffsets)} {}

    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<QueryHashIndexBindData>(
            columns, tableID, indexName, resultOffsets);
    }
};

static std::unique_ptr<TableFuncBindData> bindFunc(main::ClientContext* context,
    const TableFuncBindInput* input) {
    auto tableName = input->getLiteralVal<std::string>(0);
    auto indexName = input->getLiteralVal<std::string>(1);
    binder::Binder::validateTableExistence(*context, tableName);
    auto tableEntry =
        context->getCatalog()->getTableCatalogEntry(context->getTransaction(), tableName);
    binder::Binder::validateNodeTableType(tableEntry);
    auto tableID = tableEntry->getTableID();
    if (!context->getCatalog()->containsIndex(context->getTransaction(), tableID, indexName)) {
        throw BinderException(
            stringFormat("Table {} doesn't have an index with name {}.", tableName, indexName));
    }
    auto storageManager = context->getStorageManager();
    auto& nodeTable =
        storageManager->getTable(tableID)->cast<storage::NodeTable>();
    auto indexOpt = nodeTable.getIndex(indexName);
    if (!indexOpt.has_value()) {
        throw BinderException(
            stringFormat("Index {} not found on table {}.", indexName, tableName));
    }
    auto* index = &indexOpt.value()->cast<SecondaryHashIndex>();

    std::vector<offset_t> resultOffsets;

    if (index->isComposite()) {
        // Composite lookup: third param is comma-separated values
        auto valuesStr = input->getLiteralVal<std::string>(2);
        // Split values by comma
        std::vector<std::string> values;
        size_t start = 0;
        for (size_t i = 0; i <= valuesStr.size(); i++) {
            if (i == valuesStr.size() || valuesStr[i] == ',') {
                values.push_back(valuesStr.substr(start, i - start));
                start = i + 1;
            }
        }
        auto compositeKey = SecondaryHashIndex::buildCompositeKey(values);
        index->lookupComposite(compositeKey, resultOffsets);
    } else {
        // Single property lookup (original path)
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
            [&](int16_t) {
                auto val = static_cast<int16_t>(std::stoi(lookupValue));
                index->lookup(reinterpret_cast<const uint8_t*>(&val), resultOffsets);
            },
            [&](int8_t) {
                auto val = static_cast<int8_t>(std::stoi(lookupValue));
                index->lookup(reinterpret_cast<const uint8_t*>(&val), resultOffsets);
            },
            [&](uint64_t) {
                auto val = std::stoull(lookupValue);
                index->lookup(reinterpret_cast<const uint8_t*>(&val), resultOffsets);
            },
            [&](uint32_t) {
                auto val = static_cast<uint32_t>(std::stoul(lookupValue));
                index->lookup(reinterpret_cast<const uint8_t*>(&val), resultOffsets);
            },
            [&](uint16_t) {
                auto val = static_cast<uint16_t>(std::stoul(lookupValue));
                index->lookup(reinterpret_cast<const uint8_t*>(&val), resultOffsets);
            },
            [&](uint8_t) {
                auto val = static_cast<uint8_t>(std::stoul(lookupValue));
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
                throw BinderException("Unsupported key type for hash index query.");
            });
    }

    std::vector<std::string> columnNames = {"node_id"};
    std::vector<LogicalType> columnTypes;
    columnTypes.push_back(LogicalType::INTERNAL_ID());
    columnNames = TableFunction::extractYieldVariables(columnNames, input->yieldVariables);
    auto columns = input->binder->createVariables(columnNames, columnTypes);
    return std::make_unique<QueryHashIndexBindData>(
        std::move(columns), tableID, indexName, std::move(resultOffsets));
}

static offset_t internalTableFunc(const TableFuncMorsel& morsel, const TableFuncInput& input,
    DataChunk& output) {
    auto& bindData = *input.bindData->constPtrCast<QueryHashIndexBindData>();
    auto& nodeIDVector = output.getValueVectorMutable(0);
    auto numToOutput = morsel.endOffset - morsel.startOffset;
    for (auto i = 0u; i < numToOutput; i++) {
        auto pos = output.state->getSelVector()[i];
        nodeIDVector.setValue(pos,
            internalID_t{bindData.resultOffsets[morsel.startOffset + i], bindData.tableID});
    }
    return numToOutput;
}

function_set QueryHashIndexFunction::getFunctionSet() {
    function_set functionSet;
    auto func = std::make_unique<TableFunction>(name,
        std::vector{LogicalTypeID::STRING, LogicalTypeID::STRING, LogicalTypeID::STRING});
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

