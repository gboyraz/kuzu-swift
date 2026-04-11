#pragma once

#include "function/table/table_function.h"

namespace kuzu {
namespace range_index_extension {

struct CreateRangeIndexFunction final {
    static constexpr const char* name = "CREATE_RANGE_INDEX";
    static function::function_set getFunctionSet();
};

struct DropRangeIndexFunction final {
    static constexpr const char* name = "DROP_RANGE_INDEX";
    static function::function_set getFunctionSet();
};

struct QueryRangeIndexFunction final {
    static constexpr const char* name = "QUERY_RANGE_INDEX";
    static function::function_set getFunctionSet();
};

struct ListRangeIndexesFunction final {
    static constexpr const char* name = "LIST_RANGE_INDEXES";
    static function::function_set getFunctionSet();
};

} // namespace range_index_extension
} // namespace kuzu

