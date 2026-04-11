#include "function/range_index_functions.h"

#include "binder/binder.h"
#include "catalog/catalog.h"
#include "catalog/catalog_entry/node_table_catalog_entry.h"
#include "common/exception/binder.h"
#include "function/table/bind_data.h"
#include "function/table/simple_table_function.h"
#include "main/client_context.h"
#include "processor/execution_context.h"
#include "storage/storage_manager.h"
#include "storage/table/node_table.h"

using namespace kuzu::common;
using namespace kuzu::function;
using namespace kuzu::catalog;

namespace kuzu {
namespace range_index_extension {

struct DropRangeIndexBindData final : TableFuncBindData {
    table_id_t tableID;
    std::string tableName;
    std::string indexName;

    DropRangeIndexBindData(table_id_t tableID, std::string tableName, std::string indexName)
        : TableFuncBindData{0}, tableID{tableID}, tableName{std::move(tableName)},
          indexName{std::move(indexName)} {}

    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<DropRangeIndexBindData>(tableID, tableName, indexName);
    }
};

static std::unique_ptr<TableFuncBindData> bindFunc(main::ClientContext* context,
    const TableFuncBindInput* input) {
    if (!context->getTransactionContext()->isAutoTransaction()) {
        throw BinderException("DROP_RANGE_INDEX is only supported in auto transaction mode.");
    }
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
    return std::make_unique<DropRangeIndexBindData>(tableID, tableName, indexName);
}

static offset_t tableFunc(const TableFuncInput& input, TableFuncOutput&) {
    auto& bindData = *input.bindData->constPtrCast<DropRangeIndexBindData>();
    auto clientContext = input.context->clientContext;
    auto storageManager = clientContext->getStorageManager();
    auto& nodeTable =
        storageManager->getTable(bindData.tableID)->cast<storage::NodeTable>();
    nodeTable.dropIndex(bindData.indexName);
    clientContext->getCatalog()->dropIndex(
        clientContext->getTransaction(), bindData.tableID, bindData.indexName);
    return 0;
}

function_set DropRangeIndexFunction::getFunctionSet() {
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

