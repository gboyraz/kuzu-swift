#include "processor/operator/scan/secondary_index_scan_node_table.h"

#include "binder/expression/expression_util.h"
#include "processor/execution_context.h"
#include "storage/index/index.h"

using namespace kuzu::common;
using namespace kuzu::storage;

namespace kuzu {
namespace processor {

std::string SecondaryIndexScanPrintInfo::toString() const {
    std::string result = "IndexScan: ";
    result += propertyName;
    result += " = ";
    result += key;
    if (!alias.empty()) {
        result += ", Alias: ";
        result += alias;
    }
    result += ", Expressions: ";
    result += binder::ExpressionUtil::toString(expressions);
    return result;
}

idx_t SecondaryIndexScanSharedState::getTableIdx() {
    std::unique_lock lck{mtx};
    if (cursor < numTables) {
        return cursor++;
    }
    return numTables;
}

void SecondaryIndexScanNodeTable::initLocalStateInternal(ResultSet* resultSet,
    ExecutionContext* context) {
    ScanTable::initLocalStateInternal(resultSet, context);
    auto nodeIDVector = resultSet->getValueVector(opInfo.nodeIDPos).get();
    scanState = std::make_unique<NodeTableScanState>(nodeIDVector, std::vector<ValueVector*>{},
        nodeIDVector->state);
    indexEvaluator->init(*resultSet, context->clientContext);
}

bool SecondaryIndexScanNodeTable::getNextTuplesInternal(ExecutionContext* context) {
    auto transaction = context->clientContext->getTransaction();

    // If we haven't done the lookup yet, do it now
    if (!lookupDone) {
        currentTableIdx = sharedState->getTableIdx();
        if (currentTableIdx >= tableInfos.size()) {
            return false;
        }

        // Evaluate the key expression
        indexEvaluator->evaluate();
        auto indexVector = indexEvaluator->resultVector.get();
        auto& selVector = indexVector->state->getSelVector();
        KU_ASSERT(selVector.getSelSize() == 1);
        auto pos = selVector.getSelectedPositions()[0];
        if (indexVector->isNull(pos)) {
            return false;
        }

        // Find the secondary index on this table
        auto& tableInfo = tableInfos[currentTableIdx];
        auto& table = tableInfo.table->cast<NodeTable>();
        auto indexOpt = table.getIndex(propertyName);
        if (!indexOpt.has_value()) {
            return false;
        }
        auto* index = indexOpt.value();

        // Perform the lookup using raw key data
        auto* keyData = indexVector->getData() + indexVector->getNumBytesPerValue() * pos;
        matchedOffsets.clear();
        if (!index->lookup(keyData, matchedOffsets)) {
            return false;
        }

        currentOffsetIdx = 0;
        lookupDone = true;
    }

    // Emit one row at a time from the matched offsets
    if (currentOffsetIdx >= matchedOffsets.size()) {
        return false;
    }

    auto& tableInfo = tableInfos[currentTableIdx];
    auto& table = tableInfo.table->cast<NodeTable>();
    auto offset = matchedOffsets[currentOffsetIdx];
    currentOffsetIdx++;

    auto nodeID = nodeID_t{offset, table.getTableID()};
    // Ensure selVector is size 1 for lookup
    scanState->nodeIDVector->state->getSelVectorUnsafe().setToUnfiltered(1);
    scanState->nodeIDVector->setValue<nodeID_t>(0, nodeID);

    // Look up properties
    tableInfo.initScanState(*scanState, outVectors, context->clientContext);
    table.initScanState(transaction, *scanState, nodeID.tableID, offset);
    auto succeeded = table.lookup(transaction, *scanState);
    tableInfo.castColumns();
    if (succeeded) {
        metrics->numOutputTuple.incrementByOne();
    }
    return succeeded;
}

} // namespace processor
} // namespace kuzu

