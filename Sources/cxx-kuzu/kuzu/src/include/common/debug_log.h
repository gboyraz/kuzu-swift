#pragma once

// Opt-in, compile-time diagnostic logging for checkpoint-path observability.
//
// Enable with: -DKUZU_DEBUG_CHECKPOINT
//   - SwiftPM CLI: `swift build -Xcc -DKUZU_DEBUG_CHECKPOINT`
//   - SwiftPM test: `swift test  -Xcc -DKUZU_DEBUG_CHECKPOINT ...`
//   - Xcode iOS app: Build Settings → Other C++ Flags → add `-DKUZU_DEBUG_CHECKPOINT`
//
// When disabled (default), KUZU_CP_LOG and KUZU_CP_LOGF expand to `((void)0)` —
// the preprocessor strips the call entirely. Zero runtime cost, no branch,
// no format-string decode. Format-string arguments are not evaluated either.
//
// Motivation: tracking down #83 required on-device fprintf probes at the
// checkpoint boundary. Rather than ship those probes permanently (noisy) or
// drop them entirely (and re-land them next time), gate them behind this flag
// so iOS developers can flip it on when investigating and leave production
// builds completely clean.
//
// Probe sites currently using this macro:
//   - StorageManager::checkpoint        (per-table begin/done/fail)
//   - OnDiskHNSWIndex::checkpoint       (HNSW sub-table boundaries)
//   - Column::canCheckpointInPlace      (in-place vs out-of-place decision)
//   - NodeGroup::scanAllInsertedAndVersions (column-count drift on assert)
//   - IntegerBitpacking::setValuesFromUncompressed (bad-value dump on assert)
//
// Grep for `KUZU_CP_LOG` to audit every instrumented site.

#ifdef KUZU_DEBUG_CHECKPOINT
#include <cstdio>
// Formatted log — prefixes every line with `[KU-CP] ` and flushes stderr so
// the message is visible even if the process subsequently aborts.
#define KUZU_CP_LOG(...)                                                                           \
    do {                                                                                           \
        std::fprintf(stderr, "[KU-CP] " __VA_ARGS__);                                              \
        std::fflush(stderr);                                                                       \
    } while (0)
#else
#define KUZU_CP_LOG(...) ((void)0)
#endif
