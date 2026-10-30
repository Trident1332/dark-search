import AppKit
import WebKit

// The page menu only opens the assistant. Reading selected text is local;
// sending a question still belongs to the panel's explicit request.
extension PageView {
    func askAIItem() -> NSMenuItem? {
        guard AI.shipped || Store.testing, onAskAI != nil, canAskAI?() != false,
              let scheme = url?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        let item = NSMenuItem(title: "Ask AI…", action: #selector(askAI(_:)), keyEquivalent: "")
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
        evaluateJavaScript(AIPage.selected, in: nil, in: Web.world) { [weak self] result in
            // Navigation while WebKit answered must not attach the old
            // selection to a new page, nor open a closed tab's panel.
            guard let self, self.url == page, let onAskAI = self.onAskAI else { return }
            let selected = ((try? result.get()) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            onAskAI(selected.isEmpty ? nil : String(selected.prefix(AIPage.limit)))
        }
    }
}
