#include "function/hash_index_functions.h"

#include "binder/binder.h"
#include "catalog/catalog.h"
#include "catalog/catalog_entry/rel_group_catalog_entry.h"
#include "common/exception/binder.h"
#include "function/table/bind_data.h"
#include "function/table/simple_table_function.h"
#include "main/client_context.h"
#include "processor/execution_context.h"
#include "storage/storage_manager.h"
#include "storage/table/rel_table.h"

using namespace kuzu::common;
using namespace kuzu::function;
using namespace kuzu::catalog;

namespace kuzu {
namespace hash_index_extension {

struct DropRelIndexBindData final : TableFuncBindData {
    table_id_t relGroupID;
    table_id_t innerOid;
    std::string tableName;
    std::string indexName;

    DropRelIndexBindData(table_id_t relGroupID, table_id_t innerOid,
        std::string tableName, std::string indexName)
        : TableFuncBindData{0}, relGroupID{relGroupID}, innerOid{innerOid},
          tableName{std::move(tableName)}, indexName{std::move(indexName)} {}

    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<DropRelIndexBindData>(
            relGroupID, innerOid, tableName, indexName);
    }
};

static std::unique_ptr<TableFuncBindData> bindFunc(main::ClientContext* context,
    const TableFuncBindInput* input) {
    if (!context->getTransactionContext()->isAutoTransaction()) {
        throw BinderException(
            "DROP_REL_INDEX is only supported in auto transaction mode.");
    }
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
    return std::make_unique<DropRelIndexBindData>(
        relGroupID, innerOid, tableName, indexName);
}

static offset_t tableFunc(const TableFuncInput& input, TableFuncOutput&) {
    auto& bindData = *input.bindData->constPtrCast<DropRelIndexBindData>();
    auto clientContext = input.context->clientContext;
    auto storageManager = clientContext->getStorageManager();
    auto& relTable =
        storageManager->getTable(bindData.innerOid)->cast<storage::RelTable>();
    relTable.dropIndex(bindData.indexName);
    clientContext->getCatalog()->dropIndex(
        clientContext->getTransaction(), bindData.relGroupID, bindData.indexName);
    return 0;
}

function_set DropRelIndexFunction::getFunctionSet() {
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

