#pragma once

#include "function/table/table_function.h"

namespace kuzu {
namespace hash_index_extension {

struct CreateHashIndexFunction final {
    static constexpr const char* name = "CREATE_HASH_INDEX";
    static function::function_set getFunctionSet();
};

struct DropHashIndexFunction final {
    static constexpr const char* name = "DROP_HASH_INDEX";
    static function::function_set getFunctionSet();
};

struct QueryHashIndexFunction final {
    static constexpr const char* name = "QUERY_HASH_INDEX";
    static function::function_set getFunctionSet();
};

struct ListHashIndexesFunction final {
    static constexpr const char* name = "LIST_HASH_INDEXES";
    static function::function_set getFunctionSet();
};

} // namespace hash_index_extension
} // namespace kuzu

