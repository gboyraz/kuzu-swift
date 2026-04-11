#pragma once

#include "extension/extension.h"
#include "main/client_context.h"

namespace kuzu {
namespace hash_index_extension {

class HashIndexExtension final : public extension::Extension {
public:
    static constexpr const char* EXTENSION_NAME = "HASH_INDEX";

    void load(main::ClientContext* context);

    // Re-run index initialization after WAL recovery. This detects catalog index
    // entries that have no corresponding IndexHolder in NodeTable and rebuilds them.
    static void reconcileIndexes(main::ClientContext* context);
};

} // namespace hash_index_extension
} // namespace kuzu

