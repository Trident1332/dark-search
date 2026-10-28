import Foundation
import ObjectiveC
import WebKit

/// WebKit sets the time zone before its JavaScript process starts, so Date,
/// Intl, frames and workers use the same clock rules without page scripts.
/// These guarded engine capabilities are also required when replacing an
/// old zone: its content and service-worker processes must be stopped first.
@MainActor
enum ProxyTimeZone {
    private static let makeSelector = NSSelectorFromString("_processPoolWithConfiguration:")
    private static let setSelector = NSSelectorFromString("setTimeZoneOverride:")
    private static let closeSelector = NSSelectorFromString("_close")
    private static let terminateSelector = NSSelectorFromString("_terminateAllWebContentProcesses")
    private static let workersSelector = NSSelectorFromString("_terminateServiceWorkers")
    private static let countSelector = NSSelectorFromString("_webProcessCount")
    private static let identifiers = Set(TimeZone.knownTimeZoneIdentifiers)
    private static var cached: [String: WKProcessPool] = [:]
    static var pools: [WKProcessPool] { Array(cached.values) }

    static var isSupported: Bool {
        guard let configurationClass = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type,
              class_getClassMethod(WKProcessPool.self, makeSelector) != nil,
              class_getInstanceMethod(WKWebView.self, closeSelector) != nil,
              class_getInstanceMethod(WKProcessPool.self, terminateSelector) != nil,
              class_getInstanceMethod(WKProcessPool.self, workersSelector) != nil,
              class_getInstanceMethod(WKProcessPool.self, countSelector) != nil else { return false }
        return configurationClass.init().responds(to: setSelector)
    }

    /// Accept a known IANA identifier rather than an arbitrary fixed offset
    /// or executable text from a location response. UTC is valid explicitly.
    static func identifier(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        if value == "UTC" { return value }
        guard identifiers.contains(value), TimeZone(identifier: value) != nil else { return nil }
        return value
    }

    static func pool(for raw: String) -> WKProcessPool? {
        guard let identifier = identifier(raw), isSupported else { return nil }
        if let pool = cached[identifier] { return pool }
        guard let configurationClass = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type,
              let method = class_getClassMethod(WKProcessPool.self, makeSelector) else { return nil }
        let configuration = configurationClass.init()
        guard configuration.responds(to: setSelector) else { return nil }
        configuration.setValue(identifier, forKey: "timeZoneOverride")
        typealias Factory = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>
        let make = unsafeBitCast(method_getImplementation(method), to: Factory.self)
        guard let pool = make(WKProcessPool.self as AnyObject, makeSelector, configuration).takeUnretainedValue() as? WKProcessPool else { return nil }
        SiteLocation.provide(pool)
        cached[identifier] = pool
        return pool
    }

    static func close(_ view: WKWebView) {
        view.stopLoading()
        guard view.responds(to: closeSelector) else { return }
        invoke(closeSelector, on: view)
    }

    /// The caller closes every old view first. Keep the website stores,
    /// cookies and registrations intact; only their running processes end.
    /// A new view on the new pool then restarts workers in its own time zone.
    static func restartWorkers(in pools: [WKProcessPool]) async -> Bool {
        guard isSupported else { return false }
        var seen: Set<ObjectIdentifier> = []
        let unique = pools.filter { seen.insert(ObjectIdentifier($0)).inserted }
        guard unique.allSatisfy({ $0.responds(to: terminateSelector) && $0.responds(to: workersSelector) && $0.responds(to: countSelector) }) else { return false }
        guard !unique.isEmpty else { return !Task.isCancelled }
        // Closing a page sends asynchronous client-removal IPC. Killing its
        // process in the same turn can race that message and restart its old
        // service worker after the apparent zero-process result.
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        for _ in 0..<5 {
            for pool in unique { invoke(terminateSelector, on: pool) }
            // Allow queued worker startup/close messages to arrive before
            // deciding the pool is quiet. Retry if an old worker reappears.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            guard unique.allSatisfy({ processCount(in: $0) == 0 }) else { continue }
            // Service-worker termination requires content processes gone.
            for pool in unique { invoke(workersSelector, on: pool) }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            if unique.allSatisfy({ processCount(in: $0) == 0 }) { return !Task.isCancelled }
        }
        return false
    }

    private static func invoke(_ selector: Selector, on object: NSObject) {
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector)
    }

    private static func processCount(in pool: WKProcessPool) -> UInt {
        typealias Count = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(pool.method(for: countSelector), to: Count.self)(pool, countSelector)
    }
}
