//
//  AutomaticProperties.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//

import Foundation

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import Cocoa
#elseif canImport(WatchKit)
import WatchKit
#endif

/// Snapshot of canonical `defaultProperties` for the current device + library build.
///
/// Keys match the server's `defaultPayload` Zod schema in
/// `martech/packages/types/src/event.ts`. Unknown keys are stripped server-side,
/// so anything added here without a matching schema field is dead weight.
class AutomaticProperties {
    static let sdkVersion = "3.1.0"

    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static var defaultProperties: InternalProperties {
        var p = InternalProperties()
        p["device_vendor"] = "Apple"
        p["device_model"] = AutomaticProperties.deviceModel()
        p["version"] = "swift@\(sdkVersion)"

        #if os(iOS) || os(tvOS) || os(visionOS)
            p.merge(uiProperties()) { _, new in new }
        #elseif os(macOS)
            if let screenSize = NSScreen.main?.frame.size {
                p["screen_width"] = Int(screenSize.width)
                p["screen_height"] = Int(screenSize.height)
            }
            p["device_type"] = "desktop"
            p["os_name"] = "macOS"
            p["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        #elseif os(watchOS)
            let watchDevice = WKInterfaceDevice.current()
            let screenSize = watchDevice.screenBounds.size
            p["screen_width"] = Int(screenSize.width)
            p["screen_height"] = Int(screenSize.height)
            p["device_type"] = "watch"
            p["os_name"] = watchDevice.systemName
            p["os_version"] = watchDevice.systemVersion
        #endif

        return p
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    private struct UIPropertiesSnapshot: @unchecked Sendable {
        let values: InternalProperties
    }

    private final class UIPropertiesCache: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: UIPropertiesSnapshot?
        private var pendingQueues: [DispatchQueue] = []

        func read() -> UIPropertiesSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }

        func store(_ value: UIPropertiesSnapshot) {
            lock.lock()
            defer { lock.unlock() }
            snapshot = value
        }

        func addPendingQueue(_ queue: DispatchQueue) {
            lock.lock()
            defer { lock.unlock() }
            pendingQueues.append(queue)
        }

        func resumePendingQueues() {
            lock.lock()
            let queues = pendingQueues
            pendingQueues.removeAll()
            lock.unlock()
            for queue in queues { queue.resume() }
        }
    }

    private static let uiPropertiesCache = UIPropertiesCache()

    static func prepareUIProperties(beforeProcessing queue: DispatchQueue) {
        if Thread.isMainThread {
            primeUIPropertiesIfOnMain()
            return
        }
        // Gate the first event (including automatic events) without blocking its caller
        // or reordering track, identify, opt-out, and flush operations.
        queue.suspend()
        uiPropertiesCache.addPendingQueue(queue)
        DispatchQueue.main.async {
            primeUIPropertiesIfOnMain()
        }
    }

    static func primeUIPropertiesIfOnMain() {
        guard Thread.isMainThread else { return }
        _ = uiProperties()
        uiPropertiesCache.resumePendingQueues()
    }

    private static func uiProperties() -> InternalProperties {
        if Thread.isMainThread {
            let snapshot = MainActor.assumeIsolated { UIPropertiesSnapshot(values: makeUIProperties()) }
            uiPropertiesCache.store(snapshot)
            return snapshot.values
        }
        let snapshot = uiPropertiesCache.read()
        DispatchQueue.main.async {
            let refreshed = MainActor.assumeIsolated { UIPropertiesSnapshot(values: makeUIProperties()) }
            uiPropertiesCache.store(refreshed)
        }
        return snapshot?.values ?? [:]
    }

    @MainActor
    private static func makeUIProperties() -> InternalProperties {
        var p: InternalProperties = [:]
        #if os(iOS) || os(tvOS)
            let screenSize = UIScreen.main.bounds.size
            p["screen_width"] = Int(screenSize.width)
            p["screen_height"] = Int(screenSize.height)
            #if targetEnvironment(macCatalyst)
                p["device_type"] = "desktop"
                p["os_name"] = "macOS"
                p["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
            #else
                if isiOSAppOnMac() {
                    p["device_type"] = "desktop"
                    p["os_name"] = "macOS"
                } else {
                    #if os(tvOS)
                    p["device_type"] = "tv"
                    #else
                    p["device_type"] = "mobile"
                    #endif
                    p["os_name"] = UIDevice.current.systemName
                    p["os_version"] = UIDevice.current.systemVersion
                }
            #endif
        #elseif os(visionOS)
            p["device_type"] = "headset"
            p["os_name"] = "visionOS"
            p["os_version"] = UIDevice.current.systemVersion
        #endif
        return p
    }
    #endif

    class func deviceModel() -> String {
        var modelCode: String = "Unknown"
        if AutomaticProperties.isiOSAppOnMac() {
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            modelCode = String(cString: model)
        } else {
            var systemInfo = utsname()
            uname(&systemInfo)
            let size = MemoryLayout<CChar>.size
            modelCode = withUnsafePointer(to: &systemInfo.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: size) {
                    String(cString: UnsafePointer<CChar>($0))
                }
            }
        }
        return modelCode
    }

    class func isiOSAppOnMac() -> Bool {
        var isiOSAppOnMac = false
        if #available(iOS 14.0, macOS 11.0, watchOS 7.0, tvOS 14.0, *) {
            isiOSAppOnMac = ProcessInfo.processInfo.isiOSAppOnMac
        }
        return isiOSAppOnMac
    }

}
