# Dark Search

A small, fast, quiet web browser for the Mac, by Caroline.

![Dark Search, with its tabs down the left and a page taking the rest of the window](.github/screenshot.png)

**[Download Dark Search for macOS →](https://github.com/Trident1332/dark-search/releases/latest/download/Dark%20Search.dmg)** · macOS 14 or later · free

Dark Search 1.1.0 is maintained by Caroline, based on the open-source Search browser by [Office Commun](https://officecommun.com).

---

## What it is

Dark Search is a browser with nothing in the way. A row of tabs — across the top or down the left, your choice — and the page. There is no toolbar, no start page, no sidebar of suggestions, no account to sign into, nothing that wants your attention. You type an address or a few words in one field and you are on the page.

It uses **WebKit**, the engine already inside every Mac (it is what Safari runs on). That is why the whole app is about 8 MB on disk and opens instantly: there is no second copy of Chromium to download, update and keep in memory.

Caroline maintains this fork with its own identity and releases. The original browser was built by Office Commun; its upstream license and attribution remain included.

## What it does

- **One field.** Type an address and you go there; type words and you search. It finishes addresses from your own history and never sends what you type anywhere until you press Return.
- **Tabs that stay out of the way.** Pin the pages you keep open all day and they shrink to a letter or their icon. Tabs from your last session come back instantly and cost nothing until you click them. `⌘K` lists your open tabs by name.
- **Keep an important site running.** Enable Keep selected sites awake in Settings › Tabs, then choose Keep This Site Awake in the site card. It prevents sleeping and automatic closure, even under memory pressure, at the cost of more memory. Private choices last only in that tab; manual closing still works.
- **Two pages side by side.** Turn on Split View in Settings › Tabs, then drag a tab onto a page or choose Tabs › Split Current Page. Drag the divider to resize the panes; the outlined pane receives page commands. Pairs and their widths come back with their Space, including after a restart.
- **Reading mode.** `⇧⌘R` strips a page down to the article.
- **Hide anything, for good.** `⇧⌘H`, then click a cookie banner, a newsletter overlay, a rail of "related" nonsense — it goes, and it is still gone on that site next time, before the page has drawn a single frame.
- **An ad blocker that runs before the page.** Third-party trackers and ad networks are stopped at the network level, so there is nothing to render and nothing to slow down. On by default, off per site if something breaks.
- **Video that follows you.** `⇧⌘P` lifts the video out of the page into a small window that stays above everything, including other apps.
- **Dark Search Passwords, with Touch ID.** Website logins live in the browser's own encrypted vault. Choose an account under a sign-in field and approve Touch ID to fill it, including a password step after a username-only page. Every insertion needs a fresh biometric approval. Bring logins in from browser exports or explicitly import the old Search Keychain items; originals remain in Keychain. Nothing leaves the Mac.
- **Light, dark, or the Mac's own.** The frame and the pages follow.
- **Bookmarks, history, downloads** — each a panel, each searchable, each one keystroke away.
- **Chrome extensions, without Chrome.** Paste a Chrome Web Store link in Settings › Extensions, or open the extension's page in Dark Search and press Add. It runs on WebKit's own extension engine — the one Safari uses — and where Chrome has APIs WebKit doesn't (bookmarks, history, downloads, side panel, offscreen documents, fonts, notifications, speech, OAuth sign-in), Dark Search fills them in itself. They live behind the puzzle button; pin the ones you use often. Building your own? Load its folder as an unpacked extension and press Reload after each change, as in Chrome's developer mode. macOS 15.4 or later.
- **Call a number on a page.** Turn on Settings › Dialer, point it at your FreeSWITCH phone line, and a right-click on a phone number — selected, or just under the pointer — offers to call it. `tel:` links call too, and `⇧⌘K` opens the dialer in the side panel with a keypad and your recent calls. It is Otto's dialer, built in: a softphone over a WebSocket, the sound through WebRTC, the seat's password in your keychain. Pages on the sites you list, otto's leads table among them, can start a call themselves and take the call log back.
- **Updates itself, quietly.** Once a day it checks for a newer build, downloads it, verifies it is signed with this fork's pinned release key, and swaps it in for the next launch. Nothing restarts on its own.

## What it doesn't do

On purpose:

- No extension you have to install to feel at home. Blocking ads, hiding clutter, reading mode, picture-in-picture and passwords are built in; extensions are there for everything else.
- No sync, no account, no cloud. Your tabs, history and passwords are on your Mac and nowhere else.
- No telemetry, no analytics, no crash reports sent anywhere. The only things that leave your Mac are the pages you ask for, their icons, and one small request a day to see whether there is a newer version.
- One window. Tabs are the only kind of "new" there is.

## Privacy, concretely

| What | Where it is | Who can read it |
|---|---|---|
| Website passwords and their attached notes | `~/Library/Application Support/Search/Website Passwords/websites.vault`, encrypted with a device-bound Secure Enclave key | Opening secrets requires Touch ID. Site names, usernames and dates are metadata in the private file. |
| Legacy website logins and standalone secure notes | Existing macOS Keychain items | Legacy website secrets are read only during explicit import; standalone notes retain their Keychain storage. |
| History, bookmarks, open tabs, hidden elements | Small JSON files in `~/Library/Application Support/Search/` | You. |
| Cookies and site data | WebKit's own store for the app | The sites that set them, as in any browser. |
| Extensions | Unpacked in `~/Library/Application Support/Search/Extensions/`, their data in WebKit's extension store | Each extension, within the permissions you accepted when adding it. |
| Anything else | Nowhere. There is no server. | — |

A **private tab** (`⇧⌘N`) has its own cookie jar and leaves nothing behind when it closes.

The website vault is bound to this Mac's Secure Enclave and enrolled Touch ID. Copying its file to another Mac does not transfer the decryption key. It has no cloud recovery or master-password fallback. Explicit imports may need approval for the old login Keychain items; ordinary website fills use Touch ID.

Apps you allow in System Settings › Privacy & Security › Automation can read the address and title of your tabs with AppleScript; private tabs are never shown.

## Keyboard

| | |
|---|---|
| `⌘L` address · `⌘K` switch tab · `⌘T` new tab · `⌘W` close · `⇧⌘T` reopen | `⌘[` `⌘]` back, forward · `⇧⌘[` `⇧⌘]` previous, next tab · `⌘1`–`⌘9` jump |
| `⇧⌘S` tabs across the top or down the left · `⌘S` fold the sidebar away · `⇧⌘B` bookmark this page | `⇧⌘R` reading mode · `⇧⌘P` float the video · `⇧⌘H` hide something · `⇧⌘U` what is hidden here |
| `⌘F` find · `⌘D` duplicate tab · `⇧⌘C` copy address · `⇧⌘V` paste and go | `⌘Y` history · `⇧⌘J` downloads · `⌘,` settings · `⌥⌘L` passwords · `⇧⌘K` dialer |

Space keys (Control+1–9 by default) and the modifier used to peek at a link can be changed in Settings › Shortcuts while those features are enabled.

`⌘R` reloads the page; `⌥⌘R` reloads it from origin, checking everything cached with the site again, as Safari's Reload Page From Origin, which is also in a right-click on the reload button.

`⌃Tab` and `⌃⇧Tab` walk along the row of tabs; `Tab` stays the page's, for moving through a form. `esc` puts away whatever is open.

With Split View on, `⌥⌘N` splits the current page and `⌃⌘←` / `⌃⌘→` go from one page to the other. `⌘W` closes the focused tab and gives the remaining page the whole area. Tabs › Separate Split Tabs keeps both tabs open separately.

---

## For developers

### Why the source is here

So anyone can read exactly what a browser handling their passwords and history is doing, build it themselves, or fix something that bothers them. The code is small enough to actually read — about 42,000 lines of Swift, no dependencies beyond what Apple ships with macOS, one file per concern.

### Building it

- macOS 14 or later, Xcode 16 / Swift 6 toolchain
- `swift build` — runs the app straight from the SwiftPM binary
- `./build.sh` — assembles a real, double-clickable `Dark Search.app` in `build/`, signed so it runs on your own Mac. `SEARCH_DEV=1 ./build.sh` makes it a dev build, on a yellow icon and named for its branch (`Dark Search-split-view` from `claude/split-view-4a6927`), so it's never mistaken for an installed Dark Search or for another worktree's build; `SEARCH_FEATURE=name` picks the name. It shares the installed app's settings and its bundle id, so while both run, a link from another app may land in either

A local build uses the fork's release key when it is available, a Developer ID when available otherwise, or an ad-hoc signature. A build without the fork's release key cannot receive its automatic updates. The keychain may ask for approval when a build's signing identity changes.

`./build.sh release dmg` makes `Dark Search.dmg` and `Dark Search.zip`, each containing `Dark Search.app`. Byte-identical `Search.dmg` and `Search.zip` download aliases remain for older links. `./build.sh release ship` additionally notarizes and staples; that step needs a Developer ID certificate and Apple credentials.

Local test tools retain the real `build/Search.app` path and internal `Search` executable. `build/Dark Search.app` points to that bundle. The bundle identifier, saved-data folders, preferences and keychain services retain their existing identifiers, so upgrading keeps your browser data.

### Releases and updates in this fork

Every push to `main` runs `.github/workflows/release.yml`: it builds with `./build.sh release dmg`, signs the app and its feed with the fork's release key, and publishes them as the latest [GitHub release](https://github.com/Trident1332/dark-search/releases). An installed Dark Search reads `releases/latest/download/appcast.json.zip` at launch, every hour and at Dark Search › Check for Updates, and swaps in anything newer for the next launch.

It only accepts builds signed with that key: a self-signed certificate named "Dark Search Release Signing", pinned by hash in `Updater.signer`. The key is in the login keychain of the Mac that made it, where `./build.sh` finds and uses it, and in the repository's `SIGNING_P12` / `SIGNING_P12_PASSWORD` secrets for the workflow. A build signed any other way (ad hoc, or on a Mac without the key) runs, but never updates itself.

### How it's put together

- **SwiftUI** for everything drawn, **AppKit** for the handful of things SwiftUI doesn't reach on macOS (the window's title bar, dragging the window by an empty part of the tab row), **WKWebView** for pages.
- One `Tab` per page. Its web view is built lazily — a tab restored from last session doesn't cost a process until you switch to it. That's most of why launching with twenty tabs is still instant. Each page runs in WebKit's own content process, as in Safari; a tab you close is really gone.
- The ad blocker is a `WKContentRuleList` compiled once at launch and enforced inside WebKit's networking, before a request is made — zero cost at run time, unlike a JavaScript blocker.
- Hidden elements are a per-site list of selectors injected as a stylesheet at document start, so nothing is ever seen appearing and vanishing.
- Every colour is a light/dark pair in `Design.swift`, resolved by the window's appearance; nothing else in the code knows which mode it is in.
- Extensions run on `WKWebExtension` (macOS 15.4+). `Crx.swift` fetches an extension from the Chrome Web Store's public update address and checks the CRX3 signature against the extension's id before anything is unpacked. `Extensions.swift` is the browser's side of WebKit's contract — tabs, the window, permissions, popups. `ExtensionShims.swift` adds, at install, a small script to the extension's worker, pages and content scripts: it defines the Chrome APIs WebKit lacks — `userScripts`, `privacy`, `browsingData`, `sessions`, the old FileSystem API and more — as calls answered natively by Dark Search, and mends the places where WebKit behaves differently from Chrome: replies from pages that don't answer, listeners added after a worker starts, workers WebKit loses track of, members and constants it leaves out. Extension pages are served from `chrome-extension://<id>/`, the address they have in Chrome, so servers and sites recognise them. `./bench ext-*` drives all of it from the shell against a test run. `ExtensionNative.swift` speaks Chrome's native messaging to hosts registered in Chrome's `NativeMessagingHosts` folders.
- `Sources/Search/` is one file per concern: `Vault.swift` is the password-manager facade, `WebsitePasswordVault.swift` its encrypted store, `WebsitePasswordAuthentication.swift` its Touch ID gate, `Shield.swift` the ad blocker, `Curtain.swift` the hidden elements, `Session.swift` what comes back at launch, `Updater.swift` the update, `Bench.swift` the test socket, and so on. There's no framework of its own to learn first.

### Testing it without closing it

Turn on **Settings › General › Let a script drive Dark Search** and the running app listens on a Unix socket in its own folder (readable by your user only). `./bench` at the root of the repository speaks it:

```
./bench open https://example.com     # a tab of its own, at the end of your row, marked with a flask
./bench wait 2e7e7e89                 # until it has loaded
./bench text 2e7e7e89                 # the page's text
./bench shot 2e7e7e89 out.png         # a picture of it
./bench click 2e7e7e89 "button.go"    # click, type, submit — through the page's own events
./bench probe                         # the window's state: open panels, a modal, every window
./bench close all
```

Bench tabs are never selected for you, never enter the session or the history, and go when the script says so. It is how this browser is tested while somebody is using it.

A coding agent can drive it through `./bench-mcp`, an MCP server over the same socket: `claude mcp add search-bench -- "$PWD/bench-mcp"` (or `codex mcp add …`). Each session starts this checkout's `build/Search.app` hidden, in a test world of its own, and wipes that world when it closes; the browser you use is never in reach. Its tools read a page as roles and names, click with real mouse events, type and check what the field holds, and wait on a condition, and a handle that has gone stale or a button that is covered is an error, never a guess. `python3 Tests/bench_mcp.py` checks it end to end.

`python3 Tests/split_view.py`, after `./build.sh`, checks Split View through the app's own model in a hidden test run with its own settings and files, all removed afterwards. It never makes or shows a window; what can only be seen (dragging onto a page's edge, the divider under the pointer, the motion) is checked by hand on a release candidate.

### Contributing

Issues and pull requests are genuinely welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for how this is reviewed and what tends to get merged. The short version: small changes, no new dependencies, nothing that phones home. Found a security problem? Please report it privately, as [SECURITY.md](SECURITY.md) says.

### License

MIT — see [LICENSE](LICENSE). Dark Search is maintained by Caroline. The original Search code and upstream attribution remain credited to Office Commun; the original Search name and icon are not used for this fork's identity.
