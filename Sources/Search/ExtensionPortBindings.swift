import WebKit

/// Opaque identities for extension ports whose document may change its
/// WebKit tab adapter while the app's Tab and WKWebView stay the same.
@available(macOS 15.4, *)
@MainActor
final class ExtensionPortBindings {
    static let shared = ExtensionPortBindings()

    private final class Binding {
        weak var context: WKWebExtensionContext?
        weak var tab: Tab?
        weak var view: WKWebView?
        let tabID: Tab.ID
        let token: String

        init(context: WKWebExtensionContext, tab: Tab, view: WKWebView, token: String) {
            self.context = context
            self.tab = tab
            self.view = view
            tabID = tab.id
            self.token = token
        }
    }

    private var bindings: [String: [String: Binding]] = [:]
    private let limit: Int

    init(limit: Int = 4096) { self.limit = min(max(limit, 0), 4096) }

    /// Called only by the handler installed in this extension's isolated
    /// content world. The view comes from WKScriptMessage, never JavaScript.
    func register(_ token: String, in context: WKWebExtensionContext, view: WKWebView, owner: Extensions) -> String? {
        guard !token.isEmpty, token.count <= 128 else { return nil }
        reap(owner: owner)
        let candidates = Tab.proxyTabs.allObjects.filter { $0.built === view }
        guard candidates.count == 1, let tab = candidates.first,
              owner.portVisible(tab, for: context) else { return nil }
        let id = context.uniqueIdentifier
        if let existing = bindings[id]?.first(where: { $0.value.token == token && $0.value.context === context }) {
            return existing.value.view === view ? existing.key : nil
        }
        guard bindings[id, default: [:]].count < limit else { return nil }
        let scope = UUID().uuidString.lowercased()
        bindings[id, default: [:]][scope] = Binding(context: context, tab: tab, view: view, token: token)
        return scope
    }

    /// A keep preserves the exact Tab/view. Closing, replacing the view,
    /// revoking private access or entering Tor invalidates it permanently.
    func allowed(_ scope: String, in context: WKWebExtensionContext, owner: Extensions) -> Bool {
        let id = context.uniqueIdentifier
        guard let binding = bindings[id]?[scope] else { return false }
        guard binding.context === context else { return false }
        guard valid(binding, in: context, owner: owner) else {
            bindings[id]?[scope] = nil
            return false
        }
        return true
    }

    @discardableResult
    func unregister(_ token: String, scope: String, in context: WKWebExtensionContext, view: WKWebView) -> Bool {
        let id = context.uniqueIdentifier
        guard let binding = bindings[id]?[scope], binding.context === context,
              binding.view === view, binding.token == token else { return false }
        bindings[id]?[scope] = nil
        return true
    }

    @discardableResult
    func release(_ scope: String, in context: WKWebExtensionContext) -> Bool {
        let id = context.uniqueIdentifier
        guard bindings[id]?[scope]?.context === context else { return false }
        bindings[id]?[scope] = nil
        return true
    }

    func unregister(_ extensionID: String) { bindings[extensionID] = nil }

    /// Retirement happens synchronously with revocation, so granting access
    /// again cannot revive capabilities issued before the user revoked it.
    func revokePrivate(in context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        bindings[id] = bindings[id]?.filter { $0.value.context !== context || $0.value.tab?.shy != true }
    }

    func forget(_ tab: Tab) {
        for id in Array(bindings.keys) {
            bindings[id] = bindings[id]?.filter { $0.value.tab !== tab }
        }
    }

    private func valid(_ binding: Binding, in context: WKWebExtensionContext, owner: Extensions) -> Bool {
        guard binding.context === context, let tab = binding.tab, let view = binding.view,
              tab.id == binding.tabID, tab.built === view else { return false }
        return owner.portVisible(tab, for: context)
    }

    private func reap(owner: Extensions) {
        for id in Array(bindings.keys) {
            bindings[id] = bindings[id]?.filter { _, binding in
                guard let context = binding.context else { return false }
                return valid(binding, in: context, owner: owner)
            }
            if bindings[id]?.isEmpty == true { bindings[id] = nil }
        }
    }
}
