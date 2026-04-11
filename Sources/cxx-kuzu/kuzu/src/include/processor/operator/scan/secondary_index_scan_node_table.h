#pragma once

#include "expression_evaluator/expression_evaluator.h"
#include "processor/operator/scan/scan_node_table.h"

namespace kuzu {
namespace processor {

struct SecondaryIndexScanPrintInfo final : OPPrintInfo {
    binder::expression_vector expressions;
    std::string key;
    std::string alias;
    std::string propertyName;

    SecondaryIndexScanPrintInfo(binder::expression_vector expressions, std::string key,
        std::string alias, std::string propertyName)
        : expressions(std::move(expressions)), key(std::move(key)), alias{std::move(alias)},
          propertyName{std::move(propertyName)} {}

    std::string toString() const override;

    std::unique_ptr<OPPrintInfo> copy() const override {
        return std::unique_ptr<SecondaryIndexScanPrintInfo>(
            new SecondaryIndexScanPrintInfo(*this));
    }

private:
    SecondaryIndexScanPrintInfo(const SecondaryIndexScanPrintInfo& other)
        : OPPrintInfo(other), expressions(other.expressions), key(other.key),
          alias(other.alias), propertyName(other.propertyName) {}
};

struct SecondaryIndexScanSharedState {
    std::mutex mtx;
    common::idx_t numTables;
    common::idx_t cursor;

    explicit SecondaryIndexScanSharedState(common::idx_t numTables)
        : numTables{numTables}, cursor{0} {}

    common::idx_t getTableIdx();
};

class SecondaryIndexScanNodeTable : public ScanTable {
    static constexpr PhysicalOperatorType type_ =
        PhysicalOperatorType::SECONDARY_INDEX_SCAN_NODE_TABLE;

public:
    SecondaryIndexScanNodeTable(ScanOpInfo opInfo, std::vector<ScanNodeTableInfo> tableInfos,
        std::unique_ptr<evaluator::ExpressionEvaluator> indexEvaluator,
        std::string propertyName,
        std::shared_ptr<SecondaryIndexScanSharedState> sharedState, physical_op_id id,
        std::unique_ptr<OPPrintInfo> printInfo)
        : ScanTable{type_, std::move(opInfo), id, std::move(printInfo)}, scanState{nullptr},
          tableInfos{std::move(tableInfos)}, indexEvaluator{std::move(indexEvaluator)},
          propertyName{std::move(propertyName)}, sharedState{std::move(sharedState)},
          currentOffsetIdx{0} {}

    bool isSource() const override { return true; }

    void initLocalStateInternal(ResultSet*, ExecutionContext*) override;

    bool getNextTuplesInternal(ExecutionContext* context) override;

    bool isParallel() const override { return false; }

    std::unique_ptr<PhysicalOperator> copy() override {
        return std::make_unique<SecondaryIndexScanNodeTable>(opInfo.copy(),
            copyVector(tableInfos), indexEvaluator->copy(), propertyName, sharedState, id,
            printInfo->copy());
    }

private:
    std::unique_ptr<storage::NodeTableScanState> scanState;
    std::vector<ScanNodeTableInfo> tableInfos;
    std::unique_ptr<evaluator::ExpressionEvaluator> indexEvaluator;
    std::string propertyName;
    std::shared_ptr<SecondaryIndexScanSharedState> sharedState;

    // State for iterating over multiple offsets from index lookup
    std::vector<common::offset_t> matchedOffsets;
    common::idx_t currentOffsetIdx;
    common::idx_t currentTableIdx;
    bool lookupDone = false;
};

} // namespace processor
} // namespace kuzu

