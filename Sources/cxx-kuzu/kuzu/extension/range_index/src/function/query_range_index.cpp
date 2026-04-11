#include "function/range_index_functions.h"

#include "binder/binder.h"
#include "catalog/catalog.h"
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

struct QueryRangeIndexBindData final : TableFuncBindData {
    table_id_t tableID;
    std::string indexName;
    std::vector<offset_t> resultOffsets;

    QueryRangeIndexBindData(binder::expression_vector columns, table_id_t tableID,
        std::string indexName, std::vector<offset_t> resultOffsets)
        : TableFuncBindData{std::move(columns), resultOffsets.size()},
          tableID{tableID}, indexName{std::move(indexName)},
          resultOffsets{std::move(resultOffsets)} {}

    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<QueryRangeIndexBindData>(
            columns, tableID, indexName, resultOffsets);
    }
};

// Helper to parse a string value into a typed buffer for range lookup.
// Allocates storage in `buffer` and returns pointer to it.
template<typename T>
static const uint8_t* parseValue(const std::string& str, std::vector<uint8_t>& buffer) {
    buffer.resize(sizeof(T));
    T val;
    if constexpr (std::is_same_v<T, int64_t>) {
        val = std::stoll(str);
    } else if constexpr (std::is_same_v<T, int32_t>) {
        val = static_cast<int32_t>(std::stoi(str));
    } else if constexpr (std::is_same_v<T, int16_t>) {
        val = static_cast<int16_t>(std::stoi(str));
    } else if constexpr (std::is_same_v<T, uint64_t>) {
        val = std::stoull(str);
    } else if constexpr (std::is_same_v<T, uint32_t>) {
        val = static_cast<uint32_t>(std::stoul(str));
    } else if constexpr (std::is_same_v<T, double>) {
        val = std::stod(str);
    } else if constexpr (std::is_same_v<T, float>) {
        val = std::stof(str);
    } else {
        val = T{};
    }
    std::memcpy(buffer.data(), &val, sizeof(T));
    return buffer.data();
}

static void doRangeLookup(SecondaryRangeIndex* index, PhysicalTypeID keyType,
    const std::string& minStr, const std::string& maxStr,
    std::vector<offset_t>& resultOffsets) {
    bool hasMin = !minStr.empty();
    bool hasMax = !maxStr.empty();

    std::vector<uint8_t> minBuf, maxBuf;
    const uint8_t* minKey = nullptr;
    const uint8_t* maxKey = nullptr;
    ku_string_t minKuStr, maxKuStr;

    auto parseKeys = [&]<typename T>() {
        if (hasMin) minKey = parseValue<T>(minStr, minBuf);
        if (hasMax) maxKey = parseValue<T>(maxStr, maxBuf);
    };

    switch (keyType) {
    case PhysicalTypeID::INT64: parseKeys.template operator()<int64_t>(); break;
    case PhysicalTypeID::INT32: parseKeys.template operator()<int32_t>(); break;
    case PhysicalTypeID::INT16: parseKeys.template operator()<int16_t>(); break;
    case PhysicalTypeID::UINT64: parseKeys.template operator()<uint64_t>(); break;
    case PhysicalTypeID::UINT32: parseKeys.template operator()<uint32_t>(); break;
    case PhysicalTypeID::DOUBLE: parseKeys.template operator()<double>(); break;
    case PhysicalTypeID::FLOAT: parseKeys.template operator()<float>(); break;
    case PhysicalTypeID::STRING:
        if (hasMin) {
            minKuStr = ku_string_t(minStr.data(), minStr.size());
            minKey = reinterpret_cast<const uint8_t*>(&minKuStr);
        }
        if (hasMax) {
            maxKuStr = ku_string_t(maxStr.data(), maxStr.size());
            maxKey = reinterpret_cast<const uint8_t*>(&maxKuStr);
        }
        break;
    default:
        throw BinderException("Unsupported key type for range index query.");
    }

    index->rangeLookup(minKey, maxKey, hasMin, hasMax, resultOffsets);
}

static std::unique_ptr<TableFuncBindData> bindFunc(main::ClientContext* context,
    const TableFuncBindInput* input) {
    auto tableName = input->getLiteralVal<std::string>(0);
    auto indexName = input->getLiteralVal<std::string>(1);
    auto minStr = input->getLiteralVal<std::string>(2);
    auto maxStr = input->getLiteralVal<std::string>(3);
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
    auto& nodeTable = storageManager->getTable(tableID)->cast<storage::NodeTable>();
    auto indexOpt = nodeTable.getIndex(indexName);
    if (!indexOpt.has_value()) {
        throw BinderException(
            stringFormat("Index {} not found on table {}.", indexName, tableName));
    }
    auto* index = &indexOpt.value()->cast<SecondaryRangeIndex>();
    auto keyType = index->getIndexInfo().keyDataTypes[0];

    std::vector<offset_t> resultOffsets;
    doRangeLookup(index, keyType, minStr, maxStr, resultOffsets);

    std::vector<std::string> columnNames = {"node_id"};
    std::vector<LogicalType> columnTypes;
    columnTypes.push_back(LogicalType::INTERNAL_ID());
    columnNames = TableFunction::extractYieldVariables(columnNames, input->yieldVariables);
    auto columns = input->binder->createVariables(columnNames, columnTypes);
    return std::make_unique<QueryRangeIndexBindData>(
        std::move(columns), tableID, indexName, std::move(resultOffsets));
}

static offset_t internalTableFunc(const TableFuncMorsel& morsel, const TableFuncInput& input,
    DataChunk& output) {
    auto& bindData = *input.bindData->constPtrCast<QueryRangeIndexBindData>();
    auto& nodeIDVector = output.getValueVectorMutable(0);
    auto numToOutput = morsel.endOffset - morsel.startOffset;
    for (auto i = 0u; i < numToOutput; i++) {
        auto pos = output.state->getSelVector()[i];
        nodeIDVector.setValue(pos,
            internalID_t{bindData.resultOffsets[morsel.startOffset + i], bindData.tableID});
    }
    return numToOutput;
}

function_set QueryRangeIndexFunction::getFunctionSet() {
    function_set functionSet;
    auto func = std::make_unique<TableFunction>(name,
        std::vector{LogicalTypeID::STRING, LogicalTypeID::STRING,
                    LogicalTypeID::STRING, LogicalTypeID::STRING});
    func->tableFunc = SimpleTableFunc::getTableFunc(internalTableFunc);
    func->bindFunc = bindFunc;
    func->initSharedStateFunc = SimpleTableFunc::initSharedState;
    func->initLocalStateFunc = TableFunction::initEmptyLocalState;
    func->canParallelFunc = [] { return false; };
    functionSet.push_back(std::move(func));
    return functionSet;
}

} // namespace range_index_extension
} // namespace kuzu

