import SwiftUI

/// One connection control per tab. Tor owns its transport indicator, so a
/// separate proxy label and HTTP lock do not compete with the address.
struct ConnectionSign: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    var colour: Color = Palette.muted

    var body: some View {
        if tab.usesTor {
            TorConnectionSign(browser: browser, tab: tab, colour: colour)
        } else {
            ProxySign(browser: browser, tab: tab, colour: colour)
        }
    }
}

private struct TorConnectionSign: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    var colour: Color
    @ObservedObject private var onion = Onion.shared
    @State private var hovering = false
    @State private var showing = false

    private var onionSite: Bool {
        tab.pageAddress?.host().map(OnionAddress.isValidHost) == true
    }
    private var plainHTTP: Bool { tab.pageAddress?.scheme?.lowercased() == "http" && !onionSite }
    private var warning: Bool { !onion.ready || plainHTTP }
    private var help: String {
        if !onion.ready { return "Tor · \(onion.status)" }
        if plainHTTP { return "HTTP through Tor — the connection from its exit to this site is unencrypted" }
        return onionSite ? "Encrypted onion connection through Tor" : "Connected through Tor"
    }

    var body: some View {
        if tab.id == browser.activeID && !tab.isBlank {
            Button { showing.toggle() } label: {
                Group {
                    if onion.ready && plainHTTP {
                        Image(systemName: "lock.open")
                            .font(.system(size: 10.5, weight: .medium))
                    } else {
                        Text("Tor")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                    .foregroundStyle(warning ? Palette.unsafe : Palette.safe)
                    .frame(width: 20, height: 20)
                    .background(Palette.ink.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
            .accessibilityLabel(help)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "network").foregroundStyle(Palette.muted)
                        Text("Tor connection").fontWeight(.semibold)
                        Spacer()
                        Circle().fill(onion.ready ? Palette.safe : Palette.unsafe).frame(width: 5, height: 5)
                    }
                    .font(.system(size: 12))

                    Text(onion.ready ? "Connected · UTC" : onion.status)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)

                    if let url = tab.pageAddress, let host = url.host() {
                        Text(host)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(plainHTTP
                         ? "The connection from Tor's exit to this HTTP site is unencrypted."
                         : onionSite ? "Tor encrypts the connection to this onion service."
                         : "This tab stays on Tor, including its images and redirects.")
                        .font(.system(size: 11))
                        .foregroundStyle(plainHTTP ? Palette.unsafe : Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(Palette.hairline)
                    Button("Connection settings") {
                        showing = false
                        _ = browser.show(InternalPage(.settings, SettingsPanel.Page.proxy.rawValue))
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink)
                }
                .padding(14)
                .frame(width: 270, alignment: .leading)
                .foregroundStyle(Palette.ink)
                .background(Palette.ground)
            }
        }
    }
}
