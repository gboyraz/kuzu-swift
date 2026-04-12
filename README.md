# kuzu-swift

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2014+%20|%20macOS%2011+%20|%20Linux-blue.svg)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Embeddable property graph database for Swift. Built on [Kuzu](https://github.com/gboyraz/kuzu) with iOS/macOS optimizations, 7 index types, and a Swift-native API.

## Features

- **Graph Database** — Cypher query language, ACID transactions, WAL recovery
- **7 Index Types** — Hash, composite hash, range, HNSW vector, full-text search, unique constraint, relationship property
- **Typed Column Access** — `let name: String = try row.get(0)` with auto-conversion
- **AsyncSequence** — `for try await row in result.async { }`
- **Parameter Binding** — Arrays for `FLOAT[N]` columns and `IN` clauses
- **iOS Optimized** — Platform-tuned buffer pool, memory pressure handling
- **93+ Tests** — Comprehensive test coverage

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gboyraz/kuzu-swift.git", from: "0.12.1")
]
```

Then add `Kuzu` to your target dependencies:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "Kuzu", package: "kuzu-swift")
])
```

## Quick Start

```swift
import Kuzu

let db = try Database(path: ":memory:", bufferPoolSize: 256 * 1024 * 1024)
let conn = try Connection(database: db)

// Create schema
try conn.query("CREATE NODE TABLE Person(name STRING, age INT64, PRIMARY KEY(name))")
try conn.query("CREATE REL TABLE Follows(FROM Person TO Person)")

// Insert data
try conn.query("CREATE (:Person {name: 'Alice', age: 30})")
try conn.query("CREATE (:Person {name: 'Bob', age: 25})")
try conn.query("MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'}) CREATE (a)-[:Follows]->(b)")

// Query with typed access
let result = try conn.query("MATCH (p:Person)-[:Follows]->(f:Person) RETURN p.name, f.name, f.age")
for row in result {
    let person: String = try row.get(0)
    let friend: String = try row.get(1)
    let age: Int = try row.get(2)
    print("\(person) follows \(friend) (age \(age))")
}
```

## iOS Configuration

Optimized defaults for each platform:

| Platform | Buffer Pool | Max DB Size | Threads |
|----------|-------------|-------------|---------|
| iOS      | 512 MB      | 4 GB        | 2       |
| macOS    | 4 GB        | System default | System default |
| tvOS     | 1 GB        | System default | System default |
| watchOS  | 128 MB      | System default | System default |

```swift
let db = try Database(path: dbPath, bufferPoolSize: 768 * 1024 * 1024)
```

Keep buffer pool under 50% of device RAM for best results on iOS.

## Documentation

For detailed API documentation including index types, parameter binding, and advanced usage, see the [Wiki](../../wiki).

## System Requirements

- Swift 5.9+
- macOS 11+ / iOS 14+ / Linux
- Not supported: Windows

## Build & Test

```bash
swift build
swift test --skip StressTests    # ~2 min
swift test --filter StressTests  # Stress tests with 50K nodes
```

## Contributing

Contributions are welcome! By contributing, you agree your work will be licensed under the [MIT License](LICENSE).

## License

[MIT License](LICENSE)
