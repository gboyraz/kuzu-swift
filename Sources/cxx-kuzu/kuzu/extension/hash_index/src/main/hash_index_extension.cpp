#include "main/hash_index_extension.h"

#include "extension/extension.h"
#include "function/hash_index_functions.h"
#include "index/secondary_hash_index.h"
#include "main/database.h"

namespace kuzu {
namespace hash_index_extension {

void HashIndexExtension::load(main::ClientContext* context) {
    auto& db = *context->getDatabase();
    extension::ExtensionUtils::addStandaloneTableFunc<CreateHashIndexFunction>(db);
    extension::ExtensionUtils::addStandaloneTableFunc<DropHashIndexFunction>(db);
    extension::ExtensionUtils::addTableFunc<QueryHashIndexFunction>(db);
    extension::ExtensionUtils::registerIndexType(db, SecondaryHashIndex::getIndexType());
}

} // namespace hash_index_extension
} // namespace kuzu

