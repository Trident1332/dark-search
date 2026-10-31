# OSINT panel

Open **View → Show OSINT**, or choose **OSINT it** in a website's context menu. A clicked image or link takes priority over text; otherwise the selected text or current page supplies the query. Use the type picker when a name is ambiguous.

The panel collects public information without a paid API or required cloud model:

- People and companies: public web results, Wikidata entity candidates, and GLEIF legal entity records.
- Usernames: compatible GET/HEAD rules from the Sherlock catalog. The default checks 30 common sites; source settings can enable the complete compatible catalog. A profile match does not establish identity. Blocked, malformed and missing responses remain distinct.
- Websites and domains: fetched source and outgoing links, RDAP registration records, DNS records through Google Public DNS, certificate names through crt.sh, and archive captures through the Wayback CDX service.
- IP addresses: RDAP network allocations, RIPE routing prefixes/ASNs and reverse DNS. Registration country is not device location.
- Phone numbers: international numbering-plan validation and public web searches. The bundled libphonenumber-derived metadata does not establish assignment, current carrier or subscriber identity. Shared calling codes retain their territory distinctions.
- Images: original-byte SHA-256, ImageIO metadata including available EXIF/GPS, and on-device Vision OCR. Ordinary URLs and browser-owned blob images are supported, including images in embedded frames. Reverse image search is a separate explicit upload to Google Lens.

Source settings accept an optional SearXNG instance URL; JSON search output must be enabled on that instance. Without one, the panel attempts public web results and offers searches that can be opened in a normal tab. Free sources may rate-limit, challenge or deny requests. These responses are recorded as unavailable, not as evidence that a target does not exist.

Each finding includes collection time, provenance, raw evidence and follow-up pivots. The bookmark saves evidence under the current browser profile in `Application Support/Search/OSINT/<profile>/`, with an original image copy when applicable. Unbookmarking the final saved finding removes that saved investigation. The plus menu restores saved investigations or exports a JSON report. Queries remain in memory unless evidence is explicitly saved/exported.

**Discuss findings in Ask AI** opens an editable question backed by the complete report, independently of the question-length limit. It does not send a model request until Send is pressed. Any charges from the selected AI provider remain separate from the free OSINT collection.

Auxiliary requests follow Search's configured proxy. Queries started from a Tor tab use that tab's Tor route and isolation. Closing the panel or stopping collection invalidates outstanding results. Saved reports belong to their browser profile.

Phone metadata attribution and the Apache 2.0 license are available in `THIRD_PARTY_NOTICES.md` and in the panel's source settings. Sherlock detection rules retain their upstream source URL.
