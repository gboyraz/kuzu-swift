#include "processor/operator/scan/range_index_scan_node_table.h"

#include "binder/expression/expression_util.h"
#include "processor/execution_context.h"
#include "storage/index/index.h"

using namespace kuzu::common;
using namespace kuzu::storage;

namespace kuzu {
namespace processor {

std::string RangeIndexScanPrintInfo::toString() const {
    std::string result = "RangeIndexScan: ";
    result += propertyName;
    result += " ";
    result += rangeDesc;
    if (!alias.empty()) {
        result += ", Alias: ";
        result += alias;
    }
    result += ", Expressions: ";
    result += binder::ExpressionUtil::toString(expressions);
    return result;
}

idx_t RangeIndexScanSharedState::getTableIdx() {
    std::unique_lock lck{mtx};
    if (cursor < numTables) {
        return cursor++;
    }
    return numTables;
}

void RangeIndexScanNodeTable::initLocalStateInternal(ResultSet* resultSet,
    ExecutionContext* context) {
    ScanTable::initLocalStateInternal(resultSet, context);
    auto nodeIDVector = resultSet->getValueVector(opInfo.nodeIDPos).get();
    scanState = std::make_unique<NodeTableScanState>(nodeIDVector, std::vector<ValueVector*>{},
        nodeIDVector->state);
    if (minEvaluator) {
        minEvaluator->init(*resultSet, context->clientContext);
    }
    if (maxEvaluator) {
        maxEvaluator->init(*resultSet, context->clientContext);
    }
}

bool RangeIndexScanNodeTable::getNextTuplesInternal(ExecutionContext* context) {
    auto transaction = context->clientContext->getTransaction();

    if (!lookupDone) {
        currentTableIdx = sharedState->getTableIdx();
        if (currentTableIdx >= tableInfos.size()) {
            return false;
        }

        // Evaluate min/max key expressions
        const uint8_t* minKeyData = nullptr;
        const uint8_t* maxKeyData = nullptr;
        bool hasMin = false;
        bool hasMax = false;

        if (minEvaluator) {
            minEvaluator->evaluate();
            auto minVector = minEvaluator->resultVector.get();
            auto& selVector = minVector->state->getSelVector();
            auto pos = selVector.getSelectedPositions()[0];
            if (!minVector->isNull(pos)) {
                minKeyData = minVector->getData() + minVector->getNumBytesPerValue() * pos;
                hasMin = true;
            }
        }

        if (maxEvaluator) {
            maxEvaluator->evaluate();
            auto maxVector = maxEvaluator->resultVector.get();
            auto& selVector = maxVector->state->getSelVector();
            auto pos = selVector.getSelectedPositions()[0];
            if (!maxVector->isNull(pos)) {
                maxKeyData = maxVector->getData() + maxVector->getNumBytesPerValue() * pos;
                hasMax = true;
            }
        }

        // Find the range index on this table
        auto& tableInfo = tableInfos[currentTableIdx];
        auto& table = tableInfo.table->cast<NodeTable>();
        auto indexOpt = table.getIndex(propertyName);
        if (!indexOpt.has_value()) {
            return false;
        }
        auto* index = indexOpt.value();

        matchedOffsets.clear();
        index->rangeLookup(minKeyData, maxKeyData, hasMin, hasMax, matchedOffsets,
            minInclusive, maxInclusive);

        currentOffsetIdx = 0;
        lookupDone = true;
    }

    if (currentOffsetIdx >= matchedOffsets.size()) {
        return false;
    }

    auto& tableInfo = tableInfos[currentTableIdx];
    auto& table = tableInfo.table->cast<NodeTable>();
    const auto tableID = table.getTableID();

    const auto remaining = static_cast<idx_t>(matchedOffsets.size() - currentOffsetIdx);
    const auto numToEmit = std::min(remaining, static_cast<idx_t>(DEFAULT_VECTOR_CAPACITY));

    auto& selVector = scanState->nodeIDVector->state->getSelVectorUnsafe();
    selVector.setToUnfiltered(numToEmit);

    for (idx_t i = 0; i < numToEmit; i++) {
        auto offset = matchedOffsets[currentOffsetIdx + i];
        scanState->nodeIDVector->setValue<nodeID_t>(i, nodeID_t{offset, tableID});
    }

    tableInfo.initScanState(*scanState, outVectors, context->clientContext);
    table.lookupMultiple(transaction, *scanState);
    tableInfo.castColumns();

    currentOffsetIdx += numToEmit;

    scanState->outState->setToUnflat();
    metrics->numOutputTuple.increase(numToEmit);
    return true;
}

} // namespace processor
} // namespace kuzu

