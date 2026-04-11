#pragma once

#include "expression_evaluator/expression_evaluator.h"
#include "processor/operator/scan/scan_node_table.h"

namespace kuzu {
namespace processor {

struct RangeIndexScanPrintInfo final : OPPrintInfo {
    binder::expression_vector expressions;
    std::string alias;
    std::string propertyName;
    std::string rangeDesc;

    RangeIndexScanPrintInfo(binder::expression_vector expressions, std::string alias,
        std::string propertyName, std::string rangeDesc)
        : expressions(std::move(expressions)), alias{std::move(alias)},
          propertyName{std::move(propertyName)}, rangeDesc{std::move(rangeDesc)} {}

    std::string toString() const override;

    std::unique_ptr<OPPrintInfo> copy() const override {
        return std::unique_ptr<RangeIndexScanPrintInfo>(
            new RangeIndexScanPrintInfo(*this));
    }

private:
    RangeIndexScanPrintInfo(const RangeIndexScanPrintInfo& other)
        : OPPrintInfo(other), expressions(other.expressions), alias(other.alias),
          propertyName(other.propertyName), rangeDesc(other.rangeDesc) {}
};

struct RangeIndexScanSharedState {
    std::mutex mtx;
    common::idx_t numTables;
    common::idx_t cursor;

    explicit RangeIndexScanSharedState(common::idx_t numTables)
        : numTables{numTables}, cursor{0} {}

    common::idx_t getTableIdx();
};

class RangeIndexScanNodeTable : public ScanTable {
    static constexpr PhysicalOperatorType type_ =
        PhysicalOperatorType::RANGE_INDEX_SCAN_NODE_TABLE;

public:
    RangeIndexScanNodeTable(ScanOpInfo opInfo, std::vector<ScanNodeTableInfo> tableInfos,
        std::unique_ptr<evaluator::ExpressionEvaluator> minEvaluator,
        std::unique_ptr<evaluator::ExpressionEvaluator> maxEvaluator,
        std::string propertyName, bool minInclusive, bool maxInclusive,
        std::shared_ptr<RangeIndexScanSharedState> sharedState, physical_op_id id,
        std::unique_ptr<OPPrintInfo> printInfo)
        : ScanTable{type_, std::move(opInfo), id, std::move(printInfo)}, scanState{nullptr},
          tableInfos{std::move(tableInfos)},
          minEvaluator{std::move(minEvaluator)}, maxEvaluator{std::move(maxEvaluator)},
          propertyName{std::move(propertyName)},
          minInclusive{minInclusive}, maxInclusive{maxInclusive},
          sharedState{std::move(sharedState)}, currentOffsetIdx{0} {}

    bool isSource() const override { return true; }

    void initLocalStateInternal(ResultSet*, ExecutionContext*) override;

    bool getNextTuplesInternal(ExecutionContext* context) override;

    bool isParallel() const override { return false; }

    std::unique_ptr<PhysicalOperator> copy() override {
        return std::make_unique<RangeIndexScanNodeTable>(opInfo.copy(),
            copyVector(tableInfos),
            minEvaluator ? minEvaluator->copy() : nullptr,
            maxEvaluator ? maxEvaluator->copy() : nullptr,
            propertyName, minInclusive, maxInclusive, sharedState, id,
            printInfo->copy());
    }

private:
    std::unique_ptr<storage::NodeTableScanState> scanState;
    std::vector<ScanNodeTableInfo> tableInfos;
    std::unique_ptr<evaluator::ExpressionEvaluator> minEvaluator;
    std::unique_ptr<evaluator::ExpressionEvaluator> maxEvaluator;
    std::string propertyName;
    bool minInclusive;
    bool maxInclusive;
    std::shared_ptr<RangeIndexScanSharedState> sharedState;

    std::vector<common::offset_t> matchedOffsets;
    common::idx_t currentOffsetIdx;
    common::idx_t currentTableIdx;
    bool lookupDone = false;
};

} // namespace processor
} // namespace kuzu

