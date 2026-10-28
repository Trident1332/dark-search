# Tor engine

Search embeds a separate, unmodified Tor executable from the Tor Project's
**Tor Expert Bundle 15.0.26**, containing **Tor 0.4.9.14**. It also includes
that bundle's `libevent-2.1.7.dylib`. OpenSSL is linked into the executable.
Search adds its own Apple code signatures to the copied executable and library.

The bundle's `docs/tor.txt`, `docs/libevent.txt`, and `docs/openssl.txt` are
preserved in the app's `Contents/Resources/Tor/licenses/` directory. This
Tor build enables GPL components; the complete GPL version 3 is included there
as `GPL-3.0.txt`. Tor is a separate process, not a library linked into Search.

Source code and the corresponding reproducible build scripts are available at:

- Tor 0.4.9.14: <https://dist.torproject.org/tor-0.4.9.14.tar.gz>
- The exact upstream build configuration and dependency source locations:
  <https://gitlab.torproject.org/tpo/applications/tor-browser-build/-/tree/tbb-15.0.26-build1>
- Tor source repository: <https://gitlab.torproject.org/tpo/core/tor/-/tree/tor-0.4.9.14>
- Libevent source: <https://github.com/libevent/libevent>
- OpenSSL source: <https://github.com/openssl/openssl>

The binary downloads are pinned by architecture in `scripts/bundle-tor.py`.
Both hashes were checked against the signed 15.0.26 checksum manifest and the
archives' own detached signatures. The primary signing key fingerprint is:

`EF6E286DDA85EA2A4BA7DE684E2C6E8793298290`

The signing subkey for these files is:

`022DA248432D2A0E0F54E65E316C1FACD62D07D9`

The key and signature-verification instructions are published by the Tor Project:
<https://support.torproject.org/tor-browser/getting-started/verifying-tor-browser/>

To update the pin, verify the new release's detached signatures with this
primary key (including the signing subkey's binding), then update both archive
hashes and the versions in the script. Preserve the new upstream licenses and
source links. A normal build needs Python's standard library and Apple's
signing tools; it does not need GnuPG or a Homebrew Tor installation.

The minimal payload intentionally omits bridges, pluggable transports,
GeoIP databases, and the vendor's default configuration. Search supplies
its own client-only configuration through standard input. This feature adds
onion connectivity to Search; it is not the Tor Browser application.
