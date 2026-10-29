# Security

Dark Search is maintained by Caroline. It handles your passwords, your
history and every page you open, so a hole in it matters more than most
bugs. Please keep vulnerability details private while arranging a report.

## How to report

Check this fork's [Security tab](https://github.com/Trident1332/dark-search/security)
for reporting options. Private vulnerability reporting is currently disabled
for this repository. Open an [issue](https://github.com/Trident1332/dark-search/issues/new)
asking Caroline for a private reporting channel, without describing the
vulnerability or including sensitive data.

Once a private channel is agreed, say what you found, where in the code,
which version is affected, and how to see it happen. A proof of concept
that stays on your own machine is welcome; please don't try it on other
people's accounts or data.

Please don't open a public issue or pull request that describes the problem
until a fixed version is out. A pull request that only fixes it, without
spelling out the attack, is fine.

## What counts

Anything that lets a web page, an extension, another app or someone on the
network do more than they should: read files, passwords, cookies or
history, get around a permission, open another app without asking, or
change the app itself. Dark Search's own update, its keychain items, its
extensions layer and `./bench` are all in scope.

A site that doesn't work, or an extension that behaves differently from
Chrome, is a bug rather than a security problem: open an
[issue](https://github.com/Trident1332/dark-search/issues) for those.
