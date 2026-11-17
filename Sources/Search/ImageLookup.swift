import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ImageLookup: ObservableObject {
    @Published var link = ""
    @Published private(set) var picture: ImageLookupRequest.Picture?
    @Published private(set) var problem: String?
    @Published private(set) var loading = false
    private var task: Task<Void, Never>?
    private var revision = UUID()
    var canSearch: Bool { !loading && (picture != nil || !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    func clear() {
        revision = UUID(); task?.cancel(); task = nil
        picture = nil; link = ""; problem = nil; loading = false
    }
    func prepare(_ read: @escaping () throws -> Data) {
        clear(); loading = true
        let expected = revision
        task = Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try ImageLookupRequest.picture(read()) } }.value
            guard !Task.isCancelled, revision == expected else { return }
            loading = false
            switch result {
            case .success(let prepared): picture = prepared
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }
    func file(_ url: URL) {
        guard url.isFileURL else { return }
        prepare {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= ImageLookupRequest.limit else { throw ImageLookupRequest.Failure.tooLarge }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }
    func paste() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
            file(url)
        } else if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            prepare { data }
        } else if let text = board.string(forType: .string) {
            clear(); link = text
        } else { problem = "Copy an image or an image URL first." }
    }
    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        clear(); loading = true
        let expected = revision
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] value, _ in
                let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in
                    guard let self, self.revision == expected else { return }
                    if let url { self.file(url) } else { self.loading = false; self.problem = "Could not read the dropped image." }
                }
            }
        } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
                Task { @MainActor in
                    guard let self, self.revision == expected else { return }
                    if let data { self.prepare { data } } else { self.loading = false; self.problem = "Could not read the dropped image." }
                }
            }
        } else if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                Task { @MainActor in
                    guard let self, self.revision == expected else { return }
                    self.loading = false; self.link = url?.absoluteString ?? ""
                }
            }
        } else { loading = false; return false }
        return true
    }
    func search(in browser: Browser, endpoint: URL = ImageLookupRequest.endpoint) -> Bool {
        guard canSearch else { return false }
        guard browser.active?.usesTor != true else { problem = "Image search is unavailable in Tor tabs."; return false }
        guard !Proxy.shared.changingContent else { problem = "Wait for the proxy connection, then search again."; return false }
        do {
            let request = try ImageLookupRequest.request(picture: picture, link: link, endpoint: endpoint)
            let tab = browser.open(URL(string: "about:blank")!, foreground: true, from: browser.active)
            tab.web.stopLoading()
            tab.setAddressOptimistically(request.url!)
            tab.web.load(request)
            clear()
            return true
        } catch { problem = error.localizedDescription; return false }
    }
}

struct ImageLookupDoor: View {
    @ObservedObject var browser: Browser
    @State private var shown = false
    @State private var choosing = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "viewfinder").font(.system(size: 17, weight: .medium))
                .foregroundStyle(shown ? Color.accentColor : Palette.muted)
                .frame(width: 34, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Search by image").accessibilityLabel("Search by image")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            ImageLookupPanel(browser: browser, lookup: browser.imageLookup, close: { shown = false }, choose: {
                shown = false
                DispatchQueue.main.async { choosing = true }
            })
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                browser.imageLookup.file(url)
                shown = true
            }
        }
        .onChange(of: browser.activeID) { _, _ in shown = false; browser.imageLookup.clear() }
    }
}

struct ImageLookupPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var lookup: ImageLookup
    var close: () -> Void
    var choose: () -> Void = {}
    var drawn = false
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "photo").font(.system(size: 23)).foregroundStyle(Palette.muted)
                    .frame(width: 46, height: 46)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Search by image").font(.system(size: 18, weight: .semibold))
                    Text("Find matches, sources and similar images.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 28, height: 28).background(Palette.wash, in: Circle()) }
                    .buttonStyle(.plain).help("Close image search").accessibilityLabel("Close image search")
            }
            VStack(spacing: 10) {
                if let picture = lookup.picture {
                    Image(nsImage: picture.preview).resizable().scaledToFit().frame(maxHeight: 104).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("\(picture.width) × \(picture.height)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                } else {
                    Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(Palette.muted)
                    Text(lookup.loading ? "Preparing image…" : "Drop an image here").font(.system(size: 15, weight: .medium))
                    Text("or paste from your clipboard").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                HStack(spacing: 10) {
                    Button(lookup.picture == nil ? "Choose image" : "Change image") { choose() }
                    Button("Paste") { lookup.paste() }.help("Paste an image or image URL")
                }
                .buttonStyle(.bordered).controlSize(.regular).disabled(lookup.loading)
            }
            .frame(maxWidth: .infinity).frame(height: 190)
            .background(targeted ? Color.accentColor.opacity(0.08) : Palette.wash.opacity(0.35), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(targeted ? Color.accentColor : Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            .onDrop(of: [.fileURL, .image, .url], isTargeted: $targeted) { lookup.drop($0) }
            Text(lookup.picture == nil ? "or use an image link" : "Ready to search with this image")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "link").foregroundStyle(Palette.muted)
                    if drawn { Text(lookup.link.isEmpty ? "Paste image URL" : lookup.link).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading) }
                    else {
                        TextField("Paste image URL", text: $lookup.link).textFieldStyle(.plain)
                            .onSubmit(submit).disabled(lookup.picture != nil)
                    }
                    if lookup.picture != nil { Button { lookup.clear() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Remove selected image") }
                }
                .font(.system(size: 13)).padding(12).frame(height: 42)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12))
                Button(action: submit) { HStack(spacing: 8) { Text("Search"); Image(systemName: "arrow.right") }.padding(.horizontal, 15).frame(height: 42) }
                    .buttonStyle(.plain).background(Color.accentColor.opacity(lookup.canSearch ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white).disabled(!lookup.canSearch).accessibilityLabel("Search image with Google Lens")
            }
            if let problem = lookup.problem { Text(problem).font(.system(size: 12)).foregroundStyle(Palette.failed).fixedSize(horizontal: false, vertical: true) }
            Label("Google Lens · Your image is sent only when you search.", systemImage: "lock")
                .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
        }
        .foregroundStyle(Palette.ink).padding(24).frame(width: 520)
        .background(Palette.ground)
        .onDisappear { if !drawn { lookup.clear() } }
        .onExitCommand(perform: close)
        .onPasteCommand(of: [.image]) { _ = lookup.drop($0) }
    }
    private func submit() { if lookup.search(in: browser) { close() } }
}

