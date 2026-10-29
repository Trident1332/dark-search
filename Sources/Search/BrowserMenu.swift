import SwiftUI

/// What the three dots at the end of the address bar open: the browser's
/// own menu, laid out as Chrome's is. New tabs and windows first; then your
/// things — passwords, history, downloads, bookmarks, and clearing what's
/// kept; the page's zoom on a row of its own; what can be done with the
/// page; and Help and Settings at the end. Each row runs what the menu
/// bar's command does and shows its key as it stands (Shortcuts.swift); a
/// row with a chevron opens a menu of its own.
struct BrowserMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var keys = ShortcutStore.shared

    private var web: Bool { browser.active?.isWeb ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(icon: "plus.square", title: "New Tab", key: key("file.newTab")) { run { browser.launch() } }
            MenuRow(icon: "macwindow", title: "New Window", key: key("file.newWindow")) { run { Browsers.newWindow() } }
            MenuRow(icon: "eyeglasses", title: "New Private Tab", key: key("file.newPrivateTab")) { run { browser.newShyTab() } }
            MenuRule()
            MenuRow(icon: "key", title: "Passwords", key: key("app.passwords")) { run { browser.managing = true } }
            MenuRow(icon: "clock", title: "History", key: key("history.show")) { run { browser.recalling = true } }
            MenuRow(icon: "arrow.down.circle", title: "Downloads", key: key("history.downloads")) { run { browser.hoarding = true } }
            MenuBranch(icon: "bookmark", title: "Bookmarks") { bookmarks }
            MenuRow(icon: "trash", title: "Clear Browsing Data…", key: key("history.clearData")) { run { browser.clearBrowsingData() } }
            MenuRule()
            if let tab = browser.active {
                ZoomRow(browser: browser, tab: tab)
                MenuRule()
            }
            MenuRow(icon: "printer", title: "Print…", key: key("file.print"), enabled: web) { run { browser.printPage() } }
            if let tab = browser.active {
                TranslateRow(tab: tab, enabled: web && PageTranslator.enabled) { run { tab.toggleTranslation() } }
            }
            // On the Settings tab, ⌘F finds a setting.
            MenuRow(icon: "magnifyingglass", title: "Find on Page", key: key("edit.find"),
                    enabled: web || browser.active?.page?.kind == .settings) { run { browser.openFind() } }
            MenuRow(icon: "book", title: "Reading Mode", key: key("view.reader"), enabled: web) { run { browser.toggleReader() } }
            MenuBranch(icon: "square.and.arrow.up", title: "Save and Share") { sharing }
            MenuBranch(icon: "wrench.and.screwdriver", title: "More Tools") { tools }
            MenuRule()
            MenuBranch(icon: "questionmark.circle", title: "Help") { help }
            MenuRow(icon: "gearshape", title: "Settings", key: key("app.settings")) { run { browser.tuning = true } }
        }
        .padding(6)
        .frame(width: 300)
        .popoverGround()
    }

    /// The command's key as it stands, for the end of its row.
    private func key(_ id: String) -> String? { keys.key(for: id)?.display }

    /// The menu closes first and the row's work follows on the next turn of
    /// the loop: a card or a sheet opened while the popover is still going
    /// lands behind it, or not at all.
    private func run(_ act: @escaping () -> Void) {
        browser.menuShown = false
        DispatchQueue.main.async(execute: act)
    }

    // MARK: - the menus off the rows

    @ViewBuilder
    private var bookmarks: some View {
        Button(browser.pageKept ? "Edit Bookmark" : "Add This Page") { run { browser.bookmarkCurrent() } }
            .disabled(!web)
        Button("Manage Bookmarks") { run { browser.bookmarking = true } }
        Toggle("Show Bookmarks Bar", isOn: Binding(
            get: { browser.prefs.bookmarksBar },
            set: { browser.prefs.bookmarksBar = $0 }
        ))
        if !browser.bookmarks.isEmpty {
            Divider()
            BookmarkBranch(browser: browser, nodes: browser.bookmarks.roots, run: run)
        }
    }

    @ViewBuilder
    private var sharing: some View {
        Button("Share") { run { browser.share() } }
            .disabled(!web)
        Button("Save Page As…") { run { browser.savePage() } }
            .disabled(!web)
        Button("Export as PDF…") { run { browser.exportPDF() } }
            .disabled(!web)
        Divider()
        Button("Copy Address") { run { browser.copyAddress() } }
            .disabled(browser.active?.isBlank ?? true)
        Button("Copy Clean Link") { run { browser.copyCleanLink() } }
            .disabled(browser.active?.isBlank ?? true)
        Button("Copy as Markdown Link") { run { browser.copyMarkdownLink() } }
            .disabled(browser.active?.isBlank ?? true)
    }

    @ViewBuilder
    private var tools: some View {
        Button("Hide Elements") { run { browser.toggleHiding() } }
            .disabled(!web)
        Button("Hidden on This Site") { run { browser.reviewing.toggle() } }
            .disabled(!web)
        Button("Float Video") { run { browser.toggleFloat() } }
            .disabled(!web)
        if browser.prefs.sitesInPanel {
            Button(browser.sidePanelShown ? "Close Side Panel" : "Show Side Panel") { run { browser.toggleSitePanel() } }
        }
        if browser.prefs.dialerOn {
            Button(browser.dialerShown ? "Close Dialer" : "Show Dialer") { run { browser.toggleDialer() } }
        }
        Divider()
        Button("Bring Things Over…") { run { browser.bringingIn = "" } }
        Divider()
        Button("Web Inspector") { run { browser.toggleInspector() } }
            .disabled(!web)
        Button("JavaScript Console") { run { browser.showConsole() } }
            .disabled(!web)
    }

    @ViewBuilder
    private var help: some View {
        Button("Send Feedback") { run { Links.writeFeedback() } }
        Button("What's New") { run { _ = browser.show(InternalPage(.notes)) } }
        Button("Keyboard Shortcuts") { run { _ = browser.show(InternalPage(.settings, "keyboard")) } }
        Button("Welcome") { run { browser.welcoming = true } }
    }
}

// MARK: - the rows

/// One line as every row draws it: the icon in a column of its own, the
/// title, and the key or a chevron at the end; a grey under the one the
/// pointer is on.
private struct MenuLine: View {
    let icon: String
    let title: String
    var key: String? = nil
    var chevron = false
    var lit = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let key {
                Text(key)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(lit ? Palette.hover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// A row that does one thing.
private struct MenuRow: View {
    let icon: String
    let title: String
    var key: String? = nil
    var enabled = true
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            MenuLine(icon: icon, title: title, key: key, lit: hovering && enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// A row with a chevron: a menu of its own opens off it.
private struct MenuBranch<Items: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let items: () -> Items

    @State private var hovering = false

    var body: some View {
        // The row is drawn as its neighbours are, and the menu lies over it,
        // clear, so the whole row opens it: a Menu draws its label at the
        // label's own size, without the row's room or its chevron.
        MenuLine(icon: icon, title: title, chevron: true, lit: hovering)
            .overlay {
                Menu { items() } label: {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
    }
}

/// The line between two runs of rows.
private struct MenuRule: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }
}

/// Translate Page, or Show Original once it is (Translate.swift).
private struct TranslateRow: View {
    @ObservedObject var tab: Tab
    let enabled: Bool
    let act: () -> Void

    var body: some View {
        MenuRow(icon: "character.bubble",
                title: tab.translator != nil && tab.translation?.failed != true ? "Show Original" : "Translate Page",
                enabled: enabled, act: act)
    }
}

/// The bookmarks themselves, folders as menus of their own, under the
/// three things that aren't in the tree.
private struct BookmarkBranch: View {
    let browser: Browser
    let nodes: [Bookmark]
    let run: (@escaping () -> Void) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                Menu(node.title) {
                    if let children = node.children, !children.isEmpty {
                        BookmarkBranch(browser: browser, nodes: children, run: run)
                    } else {
                        Text("Empty")
                    }
                }
            } else if let url = node.url.flatMap(URL.init(string:)) {
                Button(node.label) { run { browser.pickBookmark(url) } }
            }
        }
    }
}

/// The page's size, as Chrome's menu has it: minus, how big it is, plus,
/// and a button for the window filling the screen. The size is pressed to
/// go back to the size every site starts at (⌘0).
private struct ZoomRow: View {
    let browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 18)
            Text("Zoom")
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                Step(icon: "minus", help: "Zoom Out") { browser.zoom(by: 1 / 1.1) }
                Rectangle().fill(Palette.hairline).frame(width: 1, height: 24)
                Button { browser.resetZoom() } label: {
                    Text("\(Int((tab.zoom * 100).rounded()))%")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                        .frame(minWidth: 44)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Actual Size")
                Rectangle().fill(Palette.hairline).frame(width: 1, height: 24)
                Step(icon: "plus", help: "Zoom In") { browser.zoom(by: 1.1) }
            }
            .frame(height: 24)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .disabled(!tab.isWeb)
            .opacity(tab.isWeb ? 1 : 0.4)
            Step(icon: "arrow.up.left.and.arrow.down.right", help: "Full Screen") {
                browser.menuShown = false
                DispatchQueue.main.async { browser.toggleFullScreen() }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private struct Step: View {
        let icon: String
        let help: String
        let act: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 28, height: 24)
                    .background(hovering ? Palette.hover : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
            .accessibilityLabel(help)
        }
    }
}
