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

    // All offsets consumed?
    if (currentOffsetIdx >= matchedOffsets.size()) {
        return false;
    }

    auto& tableInfo = tableInfos[currentTableIdx];
    auto& table = tableInfo.table->cast<NodeTable>();
    const auto tableID = table.getTableID();

    // Batch emit: fill up to DEFAULT_VECTOR_CAPACITY rows
    const auto remaining = static_cast<idx_t>(matchedOffsets.size() - currentOffsetIdx);
    const auto numToEmit = std::min(remaining, static_cast<idx_t>(DEFAULT_VECTOR_CAPACITY));

    // Set selection vector to cover the batch
    auto& selVector = scanState->nodeIDVector->state->getSelVectorUnsafe();
    selVector.setToUnfiltered(numToEmit);

    // Fill nodeIDVector with all nodeIDs for this batch
    for (idx_t i = 0; i < numToEmit; i++) {
        auto offset = matchedOffsets[currentOffsetIdx + i];
        scanState->nodeIDVector->setValue<nodeID_t>(i, nodeID_t{offset, tableID});
    }

    // Initialize scan state columns/vectors, then batch lookup
    tableInfo.initScanState(*scanState, outVectors, context->clientContext);
    table.lookupMultiple(transaction, *scanState);
    tableInfo.castColumns();

    currentOffsetIdx += numToEmit;

    // Set output state to unflat for downstream operators
    scanState->outState->setToUnflat();
    metrics->numOutputTuple.increase(numToEmit);
    return true;
}

} // namespace processor
} // namespace kuzu

