import AppKit
import WebKit

// The page menu only opens the assistant. Reading selected text is local;
// sending a question still belongs to the panel's explicit request.
extension PageView {
    func askAIItem() -> NSMenuItem? {
        guard AI.shipped || Store.testing, onAskAI != nil, canAskAI?() != false,
              let scheme = url?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        let item = NSMenuItem(title: "Ask AI", action: #selector(askAI(_:)), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("SearchAskAI")
        item.target = self
        return item
    }

    func addAskAIItem(to menu: NSMenu) {
        guard let item = askAIItem(), !menu.items.contains(where: { $0.identifier == item.identifier }) else { return }
        if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
        menu.addItem(item)
    }

    @objc private func askAI(_ item: NSMenuItem) {
        guard canAskAI?() != false,
              let page = url, ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let captured = await AISelectedText.capture(in: self)
            // Bind the exact range before opening the panel takes focus away.
            guard self.url == page, self.canAskAI?() != false, let onAskAI = self.onAskAI else {
                captured.target?.invalidate()
                return
            }
            onAskAI(captured.text.isEmpty ? nil : captured.text)
        }
    }
}
