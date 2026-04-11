#include "function/hash_index_functions.h"

#include "binder/binder.h"
#include "catalog/catalog.h"
#include "catalog/catalog_entry/index_catalog_entry.h"
#include "catalog/catalog_entry/rel_group_catalog_entry.h"
#include "common/exception/binder.h"
#include "function/table/bind_data.h"
#include "function/table/simple_table_function.h"
#include "main/client_context.h"
#include "processor/execution_context.h"

using namespace kuzu::common;
using namespace kuzu::function;
using namespace kuzu::catalog;

namespace kuzu {
namespace hash_index_extension {

struct ListRelIndexesBindData final : TableFuncBindData {
    std::vector<std::string> indexNames;
    std::vector<std::string> indexTypes;

    ListRelIndexesBindData(binder::expression_vector columns,
        std::vector<std::string> indexNames, std::vector<std::string> indexTypes)
        : TableFuncBindData{std::move(columns), indexNames.size()},
          indexNames{std::move(indexNames)}, indexTypes{std::move(indexTypes)} {}

    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<ListRelIndexesBindData>(
            columns, indexNames, indexTypes);
    }
};

static std::unique_ptr<TableFuncBindData> bindFunc(main::ClientContext* context,
    const TableFuncBindInput* input) {
    auto tableName = input->getLiteralVal<std::string>(0);
    binder::Binder::validateTableExistence(*context, tableName);
    auto tableEntry =
        context->getCatalog()->getTableCatalogEntry(context->getTransaction(), tableName);
    if (tableEntry->getType() != CatalogEntryType::REL_GROUP_ENTRY) {
        throw BinderException(stringFormat("{} is not a REL table.", tableName));
    }
    auto relGroupID = tableEntry->getTableID();

    std::vector<std::string> indexNames;
    std::vector<std::string> indexTypes;
    auto indexEntries = context->getCatalog()->getIndexEntries(
        context->getTransaction(), relGroupID);
    for (auto* indexEntry : indexEntries) {
        indexNames.push_back(indexEntry->getIndexName());
        indexTypes.push_back(indexEntry->getIndexType());
    }

    std::vector<std::string> columnNames = {"index_name", "index_type"};
    std::vector<LogicalType> columnTypes;
    columnTypes.push_back(LogicalType::STRING());
    columnTypes.push_back(LogicalType::STRING());
    columnNames =
        TableFunction::extractYieldVariables(columnNames, input->yieldVariables);
    auto columns = input->binder->createVariables(columnNames, columnTypes);
    return std::make_unique<ListRelIndexesBindData>(
        std::move(columns), std::move(indexNames), std::move(indexTypes));
}

static offset_t internalTableFunc(const TableFuncMorsel& morsel,
    const TableFuncInput& input, DataChunk& output) {
    auto& bindData = *input.bindData->constPtrCast<ListRelIndexesBindData>();
    auto& nameVector = output.getValueVectorMutable(0);
    auto& typeVector = output.getValueVectorMutable(1);
    auto numToOutput = morsel.endOffset - morsel.startOffset;
    for (auto i = 0u; i < numToOutput; i++) {
        auto pos = output.state->getSelVector()[i];
        nameVector.setValue(pos,
            std::string(bindData.indexNames[morsel.startOffset + i]));
        typeVector.setValue(pos,
            std::string(bindData.indexTypes[morsel.startOffset + i]));
    }
    return numToOutput;
}

function_set ListRelIndexesFunction::getFunctionSet() {
    function_set functionSet;
    auto func = std::make_unique<TableFunction>(name,
        std::vector{LogicalTypeID::STRING});
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

