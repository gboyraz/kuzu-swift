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

struct CreateUniqueIndexFunction final {
    static constexpr const char* name = "CREATE_UNIQUE_INDEX";
    static function::function_set getFunctionSet();
};

struct DropUniqueIndexFunction final {
    static constexpr const char* name = "DROP_UNIQUE_INDEX";
    static function::function_set getFunctionSet();
};

struct QueryUniqueIndexFunction final {
    static constexpr const char* name = "QUERY_UNIQUE_INDEX";
    static function::function_set getFunctionSet();
};

struct ListUniqueIndexesFunction final {
    static constexpr const char* name = "LIST_UNIQUE_INDEXES";
    static function::function_set getFunctionSet();
};

struct CreateRelHashIndexFunction final {
    static constexpr const char* name = "CREATE_REL_HASH_INDEX";
    static function::function_set getFunctionSet();
};

struct QueryRelHashIndexFunction final {
    static constexpr const char* name = "QUERY_REL_HASH_INDEX";
    static function::function_set getFunctionSet();
};

struct DropRelIndexFunction final {
    static constexpr const char* name = "DROP_REL_INDEX";
    static function::function_set getFunctionSet();
};

struct ListRelIndexesFunction final {
    static constexpr const char* name = "LIST_REL_INDEXES";
    static function::function_set getFunctionSet();
};

} // namespace hash_index_extension
} // namespace kuzu

