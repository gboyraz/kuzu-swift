//
//  kuzu-swift
//  https://github.com/kuzudb/kuzu-swift
//
//  Copyright © 2023 - 2025 Kùzu Inc.
//  This code is licensed under MIT license (see LICENSE for details)

import Foundation
@_implementationOnly import cxx_kuzu

/// Represents the level of memory pressure reported by the system.
public enum MemoryPressureLevel: Sendable {
    /// No memory pressure — buffer pool at full (original) size.
    case normal
    /// Moderate pressure — buffer pool reduced to 75% of original.
    case warning
    /// Significant pressure — buffer pool reduced to 50% of original.
    case critical
    /// Severe pressure — buffer pool reduced to 25% of original.
    case emergency
}

/// Represents the configuration of Kuzu database system.
///
/// The configuration includes settings for buffer pool size, thread management,
/// compression, read-only mode, and database size limits.
///
/// Platform-specific defaults:
/// - **macOS**: buffer pool 4GB, maxDBSize from system default
/// - **iOS**: buffer pool 512MB, maxDBSize 4GB, maxNumThreads 2
/// - **tvOS**: buffer pool 1GB
/// - **watchOS**: buffer pool 128MB
public final class SystemConfig: @unchecked Sendable {
    internal var cSystemConfig: kuzu_system_config

    /// Whether to automatically handle OS memory pressure events by resizing the buffer pool.
    /// When enabled, the database monitors system memory pressure and dynamically shrinks
    /// the buffer pool under pressure, restoring it when pressure eases.
    /// Default is `true`.
    public var enableMemoryPressureHandling: Bool = true

    /// Whether to enable adaptive checkpointing in the database engine.
    /// When enabled, Kuzu uses adaptive checkpoint intervals based on workload.
    /// This is applied as a runtime configuration when the database opens.
    /// Default is `true`.
    public var adaptiveCheckpoint: Bool = true

    /// Creates a new system configuration with default values.
    ///
    /// The default system configuration is as follows:
    /// - bufferPoolSize: 4GB on macOS, 512MB on iOS, 1GB on tvOS, 128MB on watchOS,
    ///   80% of system memory on Linux
    /// - maxNumThreads: 2 on iOS, number of CPU cores on other platforms
    /// - maxDBSize: 4GB on iOS, system default on other platforms
    /// - enableCompression: true
    /// - readOnly: false
    /// - threadQos: QOS_CLASS_DEFAULT (Apple platforms only)
    public init() {
        cSystemConfig = kuzu_default_system_config()
        #if os(macOS)
            cSystemConfig.buffer_pool_size = 4096 * 1024 * 1024
        #endif
        #if os(iOS)
            cSystemConfig.buffer_pool_size = 512 * 1024 * 1024
            cSystemConfig.max_db_size = 4 * 1024 * 1024 * 1024
            cSystemConfig.max_num_threads = 2
        #endif
        #if os(tvOS)
            cSystemConfig.buffer_pool_size = 1024 * 1024 * 1024
        #endif
        #if os(watchOS)
            cSystemConfig.buffer_pool_size = 128 * 1024 * 1024
        #endif
    }

    /// Creates a new system configuration with the specified parameters.
    ///
    /// - Parameters:
    ///   - bufferPoolSize: The size of the buffer pool in bytes. If 0, uses platform default.
    ///   - maxNumThreads: The maximum number of threads. If 0, uses platform default (2 on iOS, CPU cores elsewhere).
    ///   - enableCompression: A boolean flag to enable or disable compression. Default is true.
    ///   - readOnly: A boolean flag to open the database in read-only mode. Default is false.
    ///   - autoCheckpoint: Whether to automatically create checkpoints. Default is true.
    ///   - checkpointThreshold: The threshold for creating checkpoints. If set to UInt64.max, uses default value.
    ///   - maxDBSize: The maximum size of the database in bytes. If 0, uses platform default (4GB on iOS, system default elsewhere).
    public convenience init(
        bufferPoolSize: UInt64 = 0,
        maxNumThreads: UInt64 = 0,
        enableCompression: Bool = true,
        readOnly: Bool = false,
        autoCheckpoint: Bool = true,
        checkpointThreshold: UInt64 = UInt64.max,
        maxDBSize: UInt64 = 0,
        adaptiveCheckpoint: Bool = true,
        enableMemoryPressureHandling: Bool = true
    ) {
        self.init()
        if bufferPoolSize > 0 {
            cSystemConfig.buffer_pool_size = bufferPoolSize
        }
        if maxNumThreads > 0 {
            cSystemConfig.max_num_threads = maxNumThreads
        }
        cSystemConfig.enable_compression = enableCompression
        cSystemConfig.read_only = readOnly
        cSystemConfig.auto_checkpoint = autoCheckpoint
        if checkpointThreshold > 0 {
            cSystemConfig.checkpoint_threshold = checkpointThreshold
        }
        if maxDBSize > 0 {
            cSystemConfig.max_db_size = maxDBSize
        }
        self.adaptiveCheckpoint = adaptiveCheckpoint
        self.enableMemoryPressureHandling = enableMemoryPressureHandling
    }

    #if !os(Linux)
        /// Creates a new system configuration with the specified parameters and thread QoS option.
        /// This initializer is only available on Apple platforms.
        ///
        /// - Parameters:
        ///   - bufferPoolSize: The size of the buffer pool in bytes. If 0, uses platform default.
        ///   - maxNumThreads: The maximum number of threads. If 0, uses platform default (2 on iOS, CPU cores elsewhere).
        ///   - enableCompression: A boolean flag to enable or disable compression. Default is true.
        ///   - readOnly: A boolean flag to open the database in read-only mode. Default is false.
        ///   - autoCheckpoint: Whether to automatically create checkpoints. Default is true.
        ///   - checkpointThreshold: The threshold for creating checkpoints. If set to UInt64.max, uses default value.
        ///   - maxDBSize: The maximum size of the database in bytes. If 0, uses platform default (4GB on iOS, system default elsewhere).
        ///   - threadQoS: The quality of service (QoS) for the worker threads. This is only available on Apple platforms. The default value is QOS_CLASS_DEFAULT.
        public convenience init(
            bufferPoolSize: UInt64 = 0,
            maxNumThreads: UInt64 = 0,
            enableCompression: Bool = true,
            readOnly: Bool = false,
            autoCheckpoint: Bool = true,
            checkpointThreshold: UInt64 = UInt64.max,
            maxDBSize: UInt64 = 0,
            adaptiveCheckpoint: Bool = true,
            enableMemoryPressureHandling: Bool = true,
            threadQoS: qos_class_t = QOS_CLASS_DEFAULT
        ) {
            self.init(
                bufferPoolSize: bufferPoolSize,
                maxNumThreads: maxNumThreads,
                enableCompression: enableCompression,
                readOnly: readOnly,
                autoCheckpoint: autoCheckpoint,
                checkpointThreshold: checkpointThreshold,
                maxDBSize: maxDBSize,
                adaptiveCheckpoint: adaptiveCheckpoint,
                enableMemoryPressureHandling: enableMemoryPressureHandling
            )
            self.cSystemConfig.thread_qos = threadQoS.rawValue
        }
    #endif
}
