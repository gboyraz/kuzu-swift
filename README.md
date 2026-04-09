# kuzu-swift

Swift language binding for [Kuzu](https://github.com/gboyraz/kuzu), a community-maintained fork of the Kùzu embeddable property graph database. This fork includes iOS/macOS memory optimizations. For the original project, see [kuzudb/kuzu](https://github.com/kuzudb/kuzu) (archived).

## Get started

To add kuzu-swift to your Swift project, you can use the Swift Package Manager:

1. Add `.package(url: "https://github.com/gboyraz/kuzu-swift/", branch: "main"),` to your Package.swift dependencies. You can change the branch to a tag to use a specific version, e.g., `.package(url: "https://github.com/gboyraz/kuzu-swift/", branch: "0.11.0"),` to use version 0.11.0.
2. Add `Kuzu` to your target dependencies.` dependencies: [
     .product(name: "Kuzu", package: "kuzu-swift"),
 ]`

Alternatively, you can add the package through Xcode:

1. Open your Xcode project.
2. Go to `File` > `Add Packages Dependencies...`.
3. Enter the URL of the kuzu-swift repository: `https://github.com/gboyraz/kuzu-swift`.
4. Select the version you want to use (e.g., `main` branch or a specific tag).

## Docs

API documentation is coming soon.

## Examples

A simple CLI example is provided in the [Example](Example) directory.

## System requirements

kuzu-swift requires Swift 5.9 or later. It supports the following platforms:

- macOS v11 or later
- iOS v14 or later
- Linux platforms (see the [official documentation](https://www.swift.org/platform-support/) for the supported distros)

Windows platform is not supported and there is no future plan to support it.

The CI pipeline tests the package on macOS v15, Ubuntu 24.04, and iOS 18.6 Simulator.

## iOS Memory Configuration

This fork includes optimized defaults for iOS devices:

| Platform | Default Buffer Pool | Default Max DB Size | Default Threads |
|----------|-------------------|-------------------|-----------------|
| iOS | 512 MB | 4 GB | 2 |
| macOS | 4 GB | System default | System default |
| tvOS | 1 GB | System default | System default |
| watchOS | 128 MB | System default | System default |

You can customize these values:

```swift
let config = SystemConfig(
    bufferPoolSize: 768 * 1024 * 1024,  // 768 MB
    maxNumThreads: 2,
    maxDBSize: 2 * 1024 * 1024 * 1024,  // 2 GB
    autoCheckpoint: true,
    checkpointThreshold: 64 * 1024 * 1024  // 64 MB
)
let db = try Database(path, config)
```

For best performance on iOS:
- Enable autoCheckpoint with a reasonable threshold (64-256 MB)
- Keep buffer pool under 50% of device RAM to leave headroom for your app

## Build

```bash
swift build
```

## Tests

To run the tests, you can use the following commands:

```bash
swift test --skip StressTests    # Normal tests (~2 min)
swift test --filter StressTests  # Stress tests with 50K nodes (~1 min)
```

## Contributing

Contributions are welcome! By contributing to kuzu-swift, you agree that your contributions will be licensed under the [MIT License](LICENSE).