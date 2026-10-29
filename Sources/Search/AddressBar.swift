import SwiftUI

/// The row under the tabs, laid out as Chrome's toolbar is: back, forward,
/// reload and home at the left; the address in a field across the middle,
/// with the connection's sign before it and the bookmark at its end; and
/// the browser's menu behind three dots at the right, with the downloads
/// button and any extension buttons before them while there are any. The
/// page starts under it (ContentView.band), and it folds away with the
/// strip (Fold.swift). With the tabs down the side the column holds all of
/// these already, and the row isn't drawn.
struct AddressBar: View {
    @ObservedObject var browser: Browser

    var body: some View {
        HStack(spacing: 4) {
            Helm(browser: browser)
            Door(icon: "house", help: "Home") { browser.goHome() }
                .padding(.trailing, 6)
            AddressWell(browser: browser)
                .padding(.trailing, 2)
            // Only while a download is running, and a moment after.
            FetchDoor(browser: browser, fetches: browser.fetches)
            ExtensionSlot()
            MenuDoor(browser: browser)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.bar)
        .background(Palette.ground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }
}

/// The three dots, and the browser's menu behind them (BrowserMenu.swift):
/// at the end of the address bar, or in the column's foot with the tabs
/// down the side.
struct MenuDoor: View {
    @ObservedObject var browser: Browser
    var arrowEdge: Edge = .bottom

    var body: some View {
        Door(icon: "ellipsis", turned: true, on: browser.menuShown, help: "More") { browser.menuShown.toggle() }
            .popover(isPresented: $browser.menuShown, arrowEdge: arrowEdge) {
                BrowserMenu(browser: browser)
            }
            .accessibilityLabel("More")
    }
}

/// The address of the tab you're on, as the tab says it at rest
/// (AtRest.swift), with the path after it. A click brings the real field up
/// over the page with the address in it, as ⌘L does. A page of Search's own
/// says its name; a tab with nowhere to be yet says what the field is for.
private struct AddressWell: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let tab = browser.active, !tab.isBlank {
                Said(browser: browser, tab: tab)
            } else {
                Text("Search or enter address")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // The bookmark, in the field's own end, as Chrome's star is.
            BookmarkDoor(browser: browser, arrowEdge: .bottom)
        }
        .padding(.leading, 12)
        .padding(.trailing, 3)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Palette.pinLive : Palette.wash)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // A tap on the field itself; the sign, the lock and the bookmark in
        // it are buttons, and take their own clicks first.
        .onTapGesture { browser.edit() }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address")
    }

    /// Watches the tab for where it goes, and the proxy for whether its
    /// sign speaks for the connection.
    private struct Said: View {
        @ObservedObject var browser: Browser
        @ObservedObject var tab: Tab
        @ObservedObject private var proxy = Proxy.shared

        /// The connection's sign stands for the route (ProxySettings.swift,
        /// TorConnectionSign.swift): the plain lock is only for a page that
        /// takes none.
        private var routed: Bool {
            tab.usesTor || (proxy.setup.shows && proxy.routes(for: Spaces.profile(of: browser.spaceID)))
        }

        var body: some View {
            if let page = tab.page {
                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text(page.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
            } else if let rest = AtRest.said(tab.restAddress, always: true, tor: tab.usesTor) {
                ConnectionSign(browser: browser, tab: tab)
                if !routed, rest.kind == .secure || rest.kind == .onion {
                    Lock { browser.beginTabEdit(tab) }
                }
                HStack(spacing: 0) {
                    AtRestLine(rest: rest, size: 13, connectionHandled: tab.usesTor)
                    if let path = Said.path(of: tab.restAddress) {
                        Text(path)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }

        /// What follows the host, dim: the path and the query, or nothing
        /// for a site's front page.
        static func path(of url: URL?) -> String? {
            guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            var text = parts.percentEncodedPath
            if let query = parts.percentEncodedQuery, !query.isEmpty { text += "?" + query }
            if let fragment = parts.percentEncodedFragment, !fragment.isEmpty { text += "#" + fragment }
            return text.isEmpty || text == "/" ? nil : text.removingPercentEncoding ?? text
        }
    }

    /// A closed lock before a secure address. A click opens the site's card
    /// under the tab's field, as Site Information in the tab's menu does.
    private struct Lock: View {
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .frame(width: 20, height: 20)
                    .background(Palette.ink.opacity(hovering ? 0.07 : 0),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Connection is secure")
            .accessibilityLabel("Site information")
            .animation(Motion.quick, value: hovering)
        }
    }
}
