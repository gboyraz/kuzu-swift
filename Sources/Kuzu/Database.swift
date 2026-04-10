//
//  kuzu-swift
//  https://github.com/kuzudb/kuzu-swift
//
//  Copyright © 2023 - 2025 Kùzu Inc.
//  This code is licensed under MIT license (see LICENSE for details)

import Dispatch
import Foundation
@_implementationOnly import cxx_kuzu

/// A class representing a Kuzu database instance.
public final class Database: @unchecked Sendable {
    internal var cDatabase: kuzu_database

    /// The original buffer pool size configured at initialization, used to restore after pressure.
    private let originalBufferPoolSize: UInt64

    /// The current memory pressure level.
    private var currentPressureLevel: MemoryPressureLevel = .normal

    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        /// Dispatch source that monitors OS memory pressure events.
        private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    /// Initializes a new Kuzu database instance.
    /// - Parameters:
    ///   - databasePath: The path to the database. Defaults to ":memory:" for in-memory database.
    ///   - systemConfig: Optional configuration for the database system. If nil, default configuration will be used.
    /// - Throws: `KuzuError.databaseInitializationFailed` if the database initialization fails.
    public init(
        _ databasePath: String = ":memory:",
        _ systemConfig: SystemConfig? = nil
    ) throws {
        cDatabase = kuzu_database()
        let cSystemConfg =
            systemConfig?.cSystemConfig ?? kuzu_default_system_config()
        originalBufferPoolSize = cSystemConfg.buffer_pool_size
        let state = kuzu_database_init(
            databasePath,
            cSystemConfg,
            &self.cDatabase
        )
        if state == KuzuSuccess {
            let enablePressure = systemConfig?.enableMemoryPressureHandling ?? true
            if enablePressure {
                setupMemoryPressureMonitoring()
            }
            return
        } else {
            throw KuzuError.databaseInitializationFailed(
                "Database initialization failed with error code: \(state)"
            )
        }
    }

    /// Handles a memory pressure event by resizing the buffer pool.
    ///
    /// - Parameter level: The memory pressure level to respond to.
    ///
    /// The buffer pool is resized as follows:
    /// - `.normal`: restored to 100% of original size
    /// - `.warning`: reduced to 75% of original size
    /// - `.critical`: reduced to 50% of original size
    /// - `.emergency`: reduced to 25% of original size
    public func handleMemoryPressure(level: MemoryPressureLevel) {
        currentPressureLevel = level
        let ratio: Double
        switch level {
        case .normal:
            ratio = 1.0
        case .warning:
            ratio = 0.75
        case .critical:
            ratio = 0.50
        case .emergency:
            ratio = 0.25
        }
        let newSize = UInt64(Double(originalBufferPoolSize) * ratio)
        kuzu_database_resize_buffer_pool(&cDatabase, newSize)
    }

    /// The version of the Kuzu library as a string.
    ///
    /// This property returns the version of the underlying Kuzu library.
    /// Useful for debugging and ensuring compatibility.
    public static var version: String {
        let resultCString = kuzu_get_version()
        defer { kuzu_destroy_string(resultCString) }
        return String(cString: resultCString!)
    }

    /// The storage version of the Kuzu library as an unsigned 64-bit integer.
    ///
    /// This property returns the storage format version used by the Kuzu library.
    /// It can be used to check compatibility of database files.
    public static var storageVersion: UInt64 {
        let storageVersion = kuzu_get_storage_version()
        return storageVersion
    }

    deinit {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            memoryPressureSource?.cancel()
        #endif
        kuzu_database_destroy(&self.cDatabase)
    }

    // MARK: - Private

    private func setupMemoryPressureMonitoring() {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: .global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                let event = source.data
                if event.contains(.critical) {
                    self.handleMemoryPressure(level: .critical)
                } else if event.contains(.warning) {
                    self.handleMemoryPressure(level: .warning)
                }
            }
            source.setCancelHandler { /* cleanup if needed */ }
            source.resume()
            memoryPressureSource = source
        #endif
    }
}
