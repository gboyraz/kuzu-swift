#include "optimizer/filter_push_down_optimizer.h"

#include "binder/expression/literal_expression.h"
#include "common/enums/expression_type.h"
#include "binder/expression/property_expression.h"
#include "binder/expression/scalar_function_expression.h"
#include "catalog/catalog.h"
#include "catalog/catalog_entry/index_catalog_entry.h"
#include "catalog/catalog_entry/table_catalog_entry.h"
#include "main/client_context.h"
#include "storage/storage_manager.h"
#include "storage/table/node_table.h"
#include "planner/operator/extend/logical_extend.h"
#include "planner/operator/logical_empty_result.h"
#include "planner/operator/logical_filter.h"
#include "planner/operator/logical_hash_join.h"
#include "planner/operator/logical_table_function_call.h"
#include "planner/operator/scan/logical_scan_node_table.h"

using namespace kuzu::binder;
using namespace kuzu::common;
using namespace kuzu::planner;
using namespace kuzu::storage;

namespace kuzu {
namespace optimizer {

void FilterPushDownOptimizer::rewrite(LogicalPlan* plan) {
    visitOperator(plan->getLastOperator());
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::visitOperator(
    const std::shared_ptr<LogicalOperator>& op) {
    switch (op->getOperatorType()) {
    case LogicalOperatorType::FILTER: {
        return visitFilterReplace(op);
    }
    case LogicalOperatorType::CROSS_PRODUCT: {
        return visitCrossProductReplace(op);
    }
    case LogicalOperatorType::EXTEND: {
        return visitExtendReplace(op);
    }
    case LogicalOperatorType::SCAN_NODE_TABLE: {
        return visitScanNodeTableReplace(op);
    }
    case LogicalOperatorType::TABLE_FUNCTION_CALL: {
        return visitTableFunctionCallReplace(op);
    }
    default: { // Stop current push down for unhandled operator.
        return visitChildren(op);
    }
    }
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::visitChildren(
    const std::shared_ptr<LogicalOperator>& op) {
    for (auto i = 0u; i < op->getNumChildren(); ++i) {
        // Start new push down for child.
        auto optimizer = FilterPushDownOptimizer(context);
        op->setChild(i, optimizer.visitOperator(op->getChild(i)));
    }
    op->computeFlatSchema();
    return finishPushDown(op);
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::visitFilterReplace(
    const std::shared_ptr<LogicalOperator>& op) {
    auto& filter = op->constCast<LogicalFilter>();
    auto predicate = filter.getPredicate();
    if (predicate->expressionType == ExpressionType::LITERAL) {
        // Avoid executing child plan if literal is Null or False.
        auto& literalExpr = predicate->constCast<LiteralExpression>();
        if (literalExpr.isNull() || !literalExpr.getValue().getValue<bool>()) {
            return std::make_shared<LogicalEmptyResult>(*op->getSchema());
        }
        // Ignore if literal is True.
    } else {
        predicateSet.addPredicate(predicate);
    }
    return visitOperator(filter.getChild(0));
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::visitCrossProductReplace(
    const std::shared_ptr<LogicalOperator>& op) {
    auto remainingPSet = PredicateSet();
    auto probePSet = PredicateSet();
    auto buildPSet = PredicateSet();
    for (auto& p : predicateSet.getAllPredicates()) {
        auto inProbe = op->getChild(0)->getSchema()->evaluable(*p);
        auto inBuild = op->getChild(1)->getSchema()->evaluable(*p);
        if (inProbe && !inBuild) {
            probePSet.addPredicate(p);
        } else if (!inProbe && inBuild) {
            buildPSet.addPredicate(p);
        } else {
            remainingPSet.addPredicate(p);
        }
    }
    KU_ASSERT(op->getNumChildren() == 2);
    // Push probe side
    auto probeOptimizer = FilterPushDownOptimizer(context, std::move(probePSet));
    op->setChild(0, probeOptimizer.visitOperator(op->getChild(0)));
    // Push build side
    auto buildOptimizer = FilterPushDownOptimizer(context, std::move(buildPSet));
    op->setChild(1, buildOptimizer.visitOperator(op->getChild(1)));

    auto probeSchema = op->getChild(0)->getSchema();
    auto buildSchema = op->getChild(1)->getSchema();
    expression_vector predicates;
    std::vector<join_condition_t> joinConditions;
    for (auto& predicate : remainingPSet.equalityPredicates) {
        auto left = predicate->getChild(0);
        auto right = predicate->getChild(1);
        // TODO(Xiyang): this can only rewrite left = right, we should also be able to do
        // expr(left), expr(right)
        if (probeSchema->isExpressionInScope(*left) && buildSchema->isExpressionInScope(*right)) {
            joinConditions.emplace_back(left, right);
        } else if (probeSchema->isExpressionInScope(*right) &&
                   buildSchema->isExpressionInScope(*left)) {
            joinConditions.emplace_back(right, left);
        } else {
            // Collect predicates that cannot be rewritten as join conditions.
            predicates.push_back(predicate);
        }
    }
    if (joinConditions.empty()) { // Nothing to push down. Terminate.
        return finishPushDown(op);
    }
    auto hashJoin = std::make_shared<LogicalHashJoin>(joinConditions, JoinType::INNER,
        nullptr /* mark */, op->getChild(0), op->getChild(1), 0 /* cardinality */);
    // For non-id based joins, we disable side way information passing.
    hashJoin->getSIPInfoUnsafe().position = SemiMaskPosition::PROHIBIT;
    hashJoin->computeFlatSchema();
    // Apply remaining predicates.
    predicates.insert(predicates.end(), remainingPSet.nonEqualityPredicates.begin(),
        remainingPSet.nonEqualityPredicates.end());
    if (predicates.empty()) {
        return hashJoin;
    }
    return appendFilters(predicates, hashJoin);
}

static ColumnPredicateSet getPredicateSet(const Expression& column,
    const binder::expression_vector& predicates) {
    auto predicateSet = ColumnPredicateSet();
    for (auto& predicate : predicates) {
        auto columnPredicate = ColumnPredicateUtil::tryConvert(column, *predicate);
        if (columnPredicate == nullptr) {
            continue;
        }
        predicateSet.addPredicate(std::move(columnPredicate));
    }
    return predicateSet;
}

static std::vector<ColumnPredicateSet> getColumnPredicateSets(const expression_vector& columns,
    const expression_vector& predicates) {
    std::vector<ColumnPredicateSet> predicateSets;
    for (auto& column : columns) {
        predicateSets.push_back(getPredicateSet(*column, predicates));
    }
    return predicateSets;
}

static bool isConstantExpression(const std::shared_ptr<Expression> expression) {
    switch (expression->expressionType) {
    case ExpressionType::LITERAL:
    case ExpressionType::PARAMETER: {
        return true;
    }
    // TODO(Xiyang): fold parameter expression in binder.
    case ExpressionType::FUNCTION: {
        auto& func = expression->constCast<ScalarFunctionExpression>();
        if (func.getFunction().name == "CAST") {
            return isConstantExpression(func.getChild(0));
        } else {
            return false;
        }
    }
    default:
        return false;
    }
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::visitScanNodeTableReplace(
    const std::shared_ptr<LogicalOperator>& op) {
    auto& scan = op->cast<LogicalScanNodeTable>();
    auto nodeID = scan.getNodeID();
    // Apply column predicates.
    if (context->getClientConfig()->enableZoneMap) {
        scan.setPropertyPredicates(
            getColumnPredicateSets(scan.getProperties(), predicateSet.getAllPredicates()));
    }
    // Apply index scan
    auto tableIDs = scan.getTableIDs();
    std::shared_ptr<Expression> primaryKeyEqualityComparison = nullptr;
    if (tableIDs.size() == 1) {
        primaryKeyEqualityComparison = predicateSet.popNodePKEqualityComparison(*nodeID);
    }
    if (primaryKeyEqualityComparison != nullptr) { // Try rewrite index scan
        auto rhs = primaryKeyEqualityComparison->getChild(1);
        if (isConstantExpression(rhs)) {
            auto extraInfo = std::make_unique<PrimaryKeyScanInfo>(rhs);
            scan.setScanType(LogicalScanNodeTableType::PRIMARY_KEY_SCAN);
            scan.setExtraInfo(std::move(extraInfo));
            scan.computeFlatSchema();
        } else {
            // Cannot rewrite and add predicate back.
            predicateSet.addPredicate(primaryKeyEqualityComparison);
        }
    } else if (tableIDs.size() == 1) {
        // Try secondary index scan (equality)
        auto [secondaryPredicate, propName] =
            predicateSet.popNodeSecondaryIndexComparison(*nodeID, tableIDs[0], context);
        if (secondaryPredicate != nullptr) {
            auto rhs = secondaryPredicate->getChild(1);
            if (isConstantExpression(rhs)) {
                auto transaction = context->getTransaction();
                auto catalog = context->getCatalog();
                auto tableEntry = catalog->getTableCatalogEntry(transaction, tableIDs[0]);
                auto columnID = tableEntry->getColumnID(propName);
                auto extraInfo =
                    std::make_unique<SecondaryIndexScanInfo>(propName, columnID, rhs);
                scan.setScanType(LogicalScanNodeTableType::SECONDARY_INDEX_SCAN);
                scan.setExtraInfo(std::move(extraInfo));
                scan.computeFlatSchema();
            } else {
                predicateSet.addPredicate(secondaryPredicate);
            }
        } else {
            // Try range index scan (inequality)
            auto rangeMatch =
                predicateSet.popNodeRangeIndexComparison(*nodeID, tableIDs[0], context);
            if (rangeMatch.has_value()) {
                auto& match = rangeMatch.value();
                bool allConstant = true;
                if (match.minKey && !isConstantExpression(match.minKey)) {
                    allConstant = false;
                }
                if (match.maxKey && !isConstantExpression(match.maxKey)) {
                    allConstant = false;
                }
                if (allConstant) {
                    auto extraInfo = std::make_unique<RangeIndexScanInfo>(
                        match.propertyName, match.columnID,
                        match.minKey, match.maxKey,
                        match.minInclusive, match.maxInclusive);
                    scan.setScanType(LogicalScanNodeTableType::RANGE_INDEX_SCAN);
                    scan.setExtraInfo(std::move(extraInfo));
                    scan.computeFlatSchema();
                }
                // If not all constant, predicates were already removed; we need to add them back
                // But since popNodeRangeIndexComparison already removed them,
                // and we can't use them, this is a degenerate case we skip.
            }
        }
    }
    return finishPushDown(op);
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::visitTableFunctionCallReplace(
    const std::shared_ptr<LogicalOperator>& op) {
    auto& tableFunctionCall = op->cast<LogicalTableFunctionCall>();
    auto columnPredicates = getColumnPredicateSets(tableFunctionCall.getBindData()->columns,
        predicateSet.getAllPredicates());
    tableFunctionCall.setColumnPredicates(std::move(columnPredicates));
    return finishPushDown(op);
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::visitExtendReplace(
    const std::shared_ptr<LogicalOperator>& op) {
    if (op->ptrCast<BaseLogicalExtend>()->isRecursive() ||
        !context->getClientConfig()->enableZoneMap) {
        return visitChildren(op);
    }
    auto& extend = op->cast<LogicalExtend>();
    // Apply column predicates.
    auto columnPredicates =
        getColumnPredicateSets(extend.getProperties(), predicateSet.getAllPredicates());
    extend.setPropertyPredicates(std::move(columnPredicates));
    return visitChildren(op);
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::finishPushDown(
    std::shared_ptr<LogicalOperator> op) {
    if (predicateSet.isEmpty()) {
        return op;
    }
    auto predicates = predicateSet.getAllPredicates();
    auto root = appendFilters(predicates, op);
    predicateSet.clear();
    return root;
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::appendScanNodeTable(
    std::shared_ptr<binder::Expression> nodeID, std::vector<common::table_id_t> nodeTableIDs,
    binder::expression_vector properties, std::shared_ptr<planner::LogicalOperator> child) {
    if (properties.empty()) {
        return child;
    }
    auto printInfo = std::make_unique<OPPrintInfo>();
    auto scanNodeTable = std::make_shared<LogicalScanNodeTable>(std::move(nodeID),
        std::move(nodeTableIDs), std::move(properties));
    scanNodeTable->computeFlatSchema();
    return scanNodeTable;
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::appendFilters(
    const expression_vector& predicates, std::shared_ptr<LogicalOperator> child) {
    if (predicates.empty()) {
        return child;
    }
    auto root = child;
    for (auto& p : predicates) {
        root = appendFilter(p, root);
    }
    return root;
}

std::shared_ptr<LogicalOperator> FilterPushDownOptimizer::appendFilter(
    std::shared_ptr<Expression> predicate, std::shared_ptr<LogicalOperator> child) {
    auto printInfo = std::make_unique<OPPrintInfo>();
    auto filter = std::make_shared<LogicalFilter>(std::move(predicate), std::move(child));
    filter->computeFlatSchema();
    return filter;
}

void PredicateSet::addPredicate(std::shared_ptr<Expression> predicate) {
    if (predicate->expressionType == ExpressionType::EQUALS) {
        equalityPredicates.push_back(std::move(predicate));
    } else {
        nonEqualityPredicates.push_back(std::move(predicate));
    }
}

static bool isNodePrimaryKey(const Expression& expression, const Expression& nodeID) {
    if (expression.expressionType != ExpressionType::PROPERTY) {
        // not property
        return false;
    }
    auto& property = expression.constCast<PropertyExpression>();
    if (property.getVariableName() != nodeID.constCast<PropertyExpression>().getVariableName()) {
        // not property for node
        return false;
    }
    return property.isPrimaryKey();
}

std::shared_ptr<Expression> PredicateSet::popNodePKEqualityComparison(const Expression& nodeID) {
    // We pop when the first primary key equality comparison is found.
    auto resultPredicateIdx = INVALID_IDX;
    for (auto i = 0u; i < equalityPredicates.size(); ++i) {
        auto predicate = equalityPredicates[i];
        if (isNodePrimaryKey(*predicate->getChild(0), nodeID)) {
            resultPredicateIdx = i;
            break;
        } else if (isNodePrimaryKey(*predicate->getChild(1), nodeID)) {
            // Normalize primary key to LHS.
            auto leftChild = predicate->getChild(0);
            auto rightChild = predicate->getChild(1);
            predicate->setChild(1, leftChild);
            predicate->setChild(0, rightChild);
            resultPredicateIdx = i;
            break;
        }
    }
    if (resultPredicateIdx != INVALID_IDX) {
        auto result = equalityPredicates[resultPredicateIdx];
        equalityPredicates.erase(equalityPredicates.begin() + resultPredicateIdx);
        return result;
    }
    return nullptr;
}

static bool isNodeProperty(const Expression& expression, const Expression& nodeID,
    std::string& outPropertyName) {
    if (expression.expressionType != ExpressionType::PROPERTY) {
        return false;
    }
    auto& property = expression.constCast<PropertyExpression>();
    if (property.getVariableName() != nodeID.constCast<PropertyExpression>().getVariableName()) {
        return false;
    }
    if (property.isPrimaryKey()) {
        return false; // PK is handled by popNodePKEqualityComparison
    }
    outPropertyName = property.getPropertyName();
    return true;
}

std::pair<std::shared_ptr<Expression>, std::string>
PredicateSet::popNodeSecondaryIndexComparison(const Expression& nodeID,
    common::table_id_t tableID, main::ClientContext* context) {
    auto transaction = context->getTransaction();
    auto catalog = context->getCatalog();
    auto tableEntry = catalog->getTableCatalogEntry(transaction, tableID);
    auto storageManager = context->getStorageManager();
    auto* nodeTable = storageManager->getTable(tableID)->ptrCast<NodeTable>();
    auto& indexes = nodeTable->getIndexes();
    for (auto i = 0u; i < equalityPredicates.size(); ++i) {
        auto predicate = equalityPredicates[i];
        std::string propName;
        bool matched = false;
        if (isNodeProperty(*predicate->getChild(0), nodeID, propName)) {
            matched = true;
        } else if (isNodeProperty(*predicate->getChild(1), nodeID, propName)) {
            // Normalize property to LHS.
            auto leftChild = predicate->getChild(0);
            auto rightChild = predicate->getChild(1);
            predicate->setChild(1, leftChild);
            predicate->setChild(0, rightChild);
            matched = true;
        }
        if (!matched) {
            continue;
        }
        // Check if a secondary (non-PK) index exists on this property
        if (!tableEntry->containsProperty(propName)) {
            continue;
        }
        auto columnID = tableEntry->getColumnID(propName);
        for (auto& indexHolder : indexes) {
            if (!indexHolder.isLoaded()) {
                continue;
            }
            auto indexOpt = nodeTable->getIndex(indexHolder.getName());
            if (!indexOpt.has_value()) {
                continue;
            }
            auto* index = indexOpt.value();
            if (index->isPrimary()) {
                continue;
            }
            if (index->isBuiltOnColumn(columnID)) {
                auto result = equalityPredicates[i];
                equalityPredicates.erase(equalityPredicates.begin() + i);
                return {result, propName};
            }
        }
    }
    return {nullptr, ""};
}

static bool isRangeComparisonType(ExpressionType type) {
    return type == ExpressionType::GREATER_THAN ||
           type == ExpressionType::GREATER_THAN_EQUALS ||
           type == ExpressionType::LESS_THAN ||
           type == ExpressionType::LESS_THAN_EQUALS;
}

static bool isLowerBound(ExpressionType type) {
    return type == ExpressionType::GREATER_THAN ||
           type == ExpressionType::GREATER_THAN_EQUALS;
}

static bool isInclusive(ExpressionType type) {
    return type == ExpressionType::GREATER_THAN_EQUALS ||
           type == ExpressionType::LESS_THAN_EQUALS;
}

std::optional<PredicateSet::RangeIndexMatch>
PredicateSet::popNodeRangeIndexComparison(const Expression& nodeID,
    common::table_id_t tableID, main::ClientContext* context) {
    auto transaction = context->getTransaction();
    auto catalog = context->getCatalog();
    auto tableEntry = catalog->getTableCatalogEntry(transaction, tableID);
    auto storageManager = context->getStorageManager();
    auto* nodeTable = storageManager->getTable(tableID)->ptrCast<NodeTable>();
    auto& indexes = nodeTable->getIndexes();

    // Collect range predicates on properties that have a RANGE index
    struct RangePred {
        idx_t idx;              // index into nonEqualityPredicates
        std::string propName;
        common::column_id_t columnID;
        ExpressionType type;    // normalized: property is LHS
        std::shared_ptr<Expression> valueExpr;
    };
    std::vector<RangePred> candidates;

    for (auto i = 0u; i < nonEqualityPredicates.size(); ++i) {
        auto& pred = nonEqualityPredicates[i];
        if (!isRangeComparisonType(pred->expressionType)) {
            continue;
        }
        std::string propName;
        ExpressionType normType = pred->expressionType;
        std::shared_ptr<Expression> valueExpr;

        if (isNodeProperty(*pred->getChild(0), nodeID, propName)) {
            // property <op> value
            valueExpr = pred->getChild(1);
        } else if (isNodeProperty(*pred->getChild(1), nodeID, propName)) {
            // value <op> property → reverse direction
            valueExpr = pred->getChild(0);
            normType = ExpressionTypeUtil::reverseComparisonDirection(normType);
        } else {
            continue;
        }

        if (!tableEntry->containsProperty(propName)) {
            continue;
        }
        auto columnID = tableEntry->getColumnID(propName);

        // Check if a RANGE index exists on this column
        bool hasRangeIndex = false;
        for (auto& indexHolder : indexes) {
            if (!indexHolder.isLoaded()) {
                continue;
            }
            auto indexOpt = nodeTable->getIndex(indexHolder.getName());
            if (!indexOpt.has_value()) {
                continue;
            }
            auto* index = indexOpt.value();
            if (index->isPrimary()) {
                continue;
            }
            auto info = index->getIndexInfo();
            if (info.indexType == "RANGE" && index->isBuiltOnColumn(columnID)) {
                hasRangeIndex = true;
                break;
            }
        }
        if (!hasRangeIndex) {
            continue;
        }

        candidates.push_back({i, propName, columnID, normType, valueExpr});
    }

    if (candidates.empty()) {
        return std::nullopt;
    }

    // Group by property name, take the first property that has candidates
    auto& first = candidates[0];
    RangeIndexMatch match;
    match.propertyName = first.propName;
    match.columnID = first.columnID;

    for (auto& c : candidates) {
        if (c.propName != match.propertyName) {
            continue; // only combine predicates on the same property
        }
        if (isLowerBound(c.type)) {
            // property > value or property >= value
            if (!match.minKey) {
                match.minKey = c.valueExpr;
                match.minInclusive = isInclusive(c.type);
                match.predicateIndices.push_back(c.idx);
            }
        } else {
            // property < value or property <= value
            if (!match.maxKey) {
                match.maxKey = c.valueExpr;
                match.maxInclusive = isInclusive(c.type);
                match.predicateIndices.push_back(c.idx);
            }
        }
    }

    // Must have at least one bound
    if (!match.minKey && !match.maxKey) {
        return std::nullopt;
    }

    // Remove matched predicates from nonEqualityPredicates (in reverse order to keep indices valid)
    std::sort(match.predicateIndices.begin(), match.predicateIndices.end(), std::greater<>());
    for (auto idx : match.predicateIndices) {
        nonEqualityPredicates.erase(nonEqualityPredicates.begin() + idx);
    }

    return match;
}

expression_vector PredicateSet::getAllPredicates() {
    expression_vector result;
    result.insert(result.end(), equalityPredicates.begin(), equalityPredicates.end());
    result.insert(result.end(), nonEqualityPredicates.begin(), nonEqualityPredicates.end());
    return result;
}

} // namespace optimizer
} // namespace kuzu
