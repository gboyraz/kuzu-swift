#include "function/range_index_functions.h"

#include "binder/binder.h"
#include "catalog/catalog.h"
#include "catalog/catalog_entry/index_catalog_entry.h"
#include "catalog/catalog_entry/node_table_catalog_entry.h"
#include "common/exception/binder.h"
#include "function/table/bind_data.h"
#include "function/table/simple_table_function.h"
#include "main/client_context.h"
#include "processor/execution_context.h"

using namespace kuzu::common;
using namespace kuzu::function;
using namespace kuzu::catalog;

namespace kuzu {
namespace range_index_extension {

struct ListRangeIndexesBindData final : TableFuncBindData {
    std::vector<std::string> propertyNames;

    ListRangeIndexesBindData(binder::expression_vector columns,
        std::vector<std::string> propertyNames)
        : TableFuncBindData{std::move(columns), propertyNames.size()},
          propertyNames{std::move(propertyNames)} {}

    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<ListRangeIndexesBindData>(columns, propertyNames);
    }
};

static std::unique_ptr<TableFuncBindData> bindFunc(main::ClientContext* context,
    const TableFuncBindInput* input) {
    auto tableName = input->getLiteralVal<std::string>(0);
    binder::Binder::validateTableExistence(*context, tableName);
    auto tableEntry =
        context->getCatalog()->getTableCatalogEntry(context->getTransaction(), tableName);
    binder::Binder::validateNodeTableType(tableEntry);
    auto tableID = tableEntry->getTableID();

    std::vector<std::string> propertyNames;
    auto indexEntries =
        context->getCatalog()->getIndexEntries(context->getTransaction(), tableID);
    for (auto* indexEntry : indexEntries) {
        if (indexEntry->getIndexType() == "RANGE") {
            propertyNames.push_back(indexEntry->getIndexName());
        }
    }

    std::vector<std::string> columnNames = {"property_name"};
    std::vector<LogicalType> columnTypes;
    columnTypes.push_back(LogicalType::STRING());
    columnNames = TableFunction::extractYieldVariables(columnNames, input->yieldVariables);
    auto columns = input->binder->createVariables(columnNames, columnTypes);
    return std::make_unique<ListRangeIndexesBindData>(
        std::move(columns), std::move(propertyNames));
}

static offset_t internalTableFunc(const TableFuncMorsel& morsel, const TableFuncInput& input,
    DataChunk& output) {
    auto& bindData = *input.bindData->constPtrCast<ListRangeIndexesBindData>();
    auto& nameVector = output.getValueVectorMutable(0);
    auto numToOutput = morsel.endOffset - morsel.startOffset;
    for (auto i = 0u; i < numToOutput; i++) {
        auto pos = output.state->getSelVector()[i];
        nameVector.setValue(pos,
            std::string(bindData.propertyNames[morsel.startOffset + i]));
    }
    return numToOutput;
}

function_set ListRangeIndexesFunction::getFunctionSet() {
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

} // namespace range_index_extension
} // namespace kuzu

