# Contributing

Dark Search is a fork maintained by Caroline, based on [Search by Office Commun](https://github.com/driceroland/Search). Contributions to this fork are welcome, but a few things make one land faster.

## Before writing code

For anything beyond a small fix, open an [issue in this repository](https://github.com/Trident1332/dark-search/issues/new) first describing what you want to change and why. It saves a rewritten pull request later if the direction doesn't fit.

## New features: off until someone turns them on

Dark Search stays small by default. Anything new that changes how the browser
looks or behaves — spaces, groups, a visible address bar, a new panel — is:

- **minimal**: the smallest version that does the job, in the app's own quiet style;
- **optional, and off by default**: someone who never asks for it never sees it;
- **findable**: a switch in Settings, and a mention in the welcome screens if it's a big one, so people know it's there to turn on.

Fixes and things every browser is expected to do (Tab moving between a form's fields, ⌘1–⌘9) don't need a switch. Before building a bigger feature, look at how other browsers do it and read what people asked for on its issue; [ROADMAP.md](ROADMAP.md) lists where each request came from.

## Where things are tracked

- [Issues](https://github.com/Trident1332/dark-search/issues) and [pull requests](https://github.com/Trident1332/dark-search/pulls) track work on this fork. [ROADMAP.md](ROADMAP.md) also retains ideas and reports inherited from the upstream project, with their source links.
- [CHANGELOG.md](CHANGELOG.md): what has changed since the last version. A pull request that fixes or adds something also adds its line under **Unreleased** (and takes its item off the roadmap), so the next update's notes write themselves.

## What tends to get merged

- **Small, focused changes.** One thing per pull request, easy to read start to finish.
- **No new dependencies.** The whole point of this app is staying small; a browser this size doesn't need a package for something Foundation or WebKit already does.
- **Matches the existing style.** Comments here explain *why*, not *what the next line does* — read a couple of existing files before adding a new one. No force-unwraps on anything that can plausibly fail (a network response, a file read, a keychain lookup).
- **Builds clean.** `swift build` with zero warnings you introduced.

## What doesn't

- Rewrites of things that already work, for style reasons alone.
- Anything that phones home, adds analytics, or changes what leaves the app over the network — see the [privacy notes](README.md#privacy-concretely) for what that boundary currently is.
- Vendoring Chromium or any other engine. This is a WebKit browser on purpose.
- A real key or token anywhere: in code, a test, an issue, a pull request or a pasted log. Tests use keys that are obviously made up. `gitleaks git --pre-commit --staged` with the repo's `.gitleaks.toml` catches most of them before a commit; it is worth running as a pre-commit hook.

## Review

Caroline maintains this fork and reviews its [pull requests](https://github.com/Trident1332/dark-search/pulls). Keep the description focused on what changes, why, and how it was checked. Pinging a stale PR after a couple of weeks is completely fine.

## Reporting a bug

Open an [issue](https://github.com/Trident1332/dark-search/issues/new) with: what you did, what you expected, what happened instead, and your macOS version. For a security problem, follow [SECURITY.md](SECURITY.md) instead. A crash log, if there is one, lives at `~/Library/Application Support/Search/crash.log` — the existing data directory is retained for compatibility, and the log only stays on your Mac unless you paste it into the issue yourself.
