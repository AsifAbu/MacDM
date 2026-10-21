import SwiftUI

/// Everything the Site Grabber window does, apart from drawing it.
@MainActor
final class SiteGrabberModel: ObservableObject {
    @Published var pageURLString = ""
    @Published var depth = 0                       // 0 = this page only, 1 or 2 = also pages it links to on the same site
    @Published var links: [GrabbedLink] = []
    @Published var selected: Set<URL> = []
    @Published var filter = GrabFilter()
    @Published var minSizeMB = ""
    @Published var isScanning = false
    @Published var statusText = ""
    @Published var errorText: String?
    @Published var fromBrowser = false

    private(set) var session: GrabSession?
    private var scanTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?

    var visible: [GrabbedLink] { links.filter(filter.matches) }

    func count(of kind: GrabKind) -> Int { links.filter { $0.kind == kind }.count }

    /// Shows links sent from the browser: the page as the user sees it, logged in.
    func load(_ session: GrabSession) {
        stop()
        self.session = session
        fromBrowser = true
        pageURLString = session.pageURL.absoluteString
        links = session.links
        selected = []
        errorText = nil
        statusText = "\(session.links.count) links from your browser"
        readSizes()
    }

    func scan() {
        guard let pageURL = RequestSecurity.webURL(from: pageURLString.trimmingCharacters(in: .whitespaces)) else {
            errorText = "Enter a web address that starts with http:// or https://"
            return
        }
        stop()
        isScanning = true
        errorText = nil
        links = []
        selected = []
        statusText = "Reading the page…"
        let headers = session?.headers(for: pageURL) ?? [:]
        let depth = self.depth

        scanTask = Task {
            let crawler = SiteCrawler(headers: headers)
            let found = await crawler.crawl(start: pageURL, depth: depth) { progress in
                Task { @MainActor [weak self] in
                    self?.statusText = "Read \(progress.pagesScanned) page(s), found \(progress.filesFound) file(s)…"
                }
            }
            guard !Task.isCancelled else { return }
            links = found
            isScanning = false
            statusText = found.isEmpty ? "" : "Found \(found.count) file(s)"
            if found.isEmpty { errorText = "No downloadable files were found on this page. If it needs a login, use “Grab links” from the MacDM button in Chrome." }
            readSizes()
        }
    }

    func stop() {
        scanTask?.cancel(); probeTask?.cancel()
        isScanning = false
    }

    /// Looks up file sizes in the background so they can be shown and filtered by.
    private func readSizes() {
        probeTask?.cancel()
        let pending = links.filter { $0.size == nil }.prefix(400).map(\.url)
        guard !pending.isEmpty else { return }
        var headersByURL: [URL: [String: String]] = [:]
        for url in pending { headersByURL[url] = session?.headers(for: url) ?? ["Referer": pageURLString] }
        probeTask = Task {
            await SizeProber.probe(pending, headers: headersByURL) { url, size, type in
                Task { @MainActor [weak self] in
                    guard let self, let index = self.links.firstIndex(where: { $0.url == url }) else { return }
                    self.links[index].size = size
                    self.links[index].kind = GrabKind.of(contentType: type, fallback: self.links[index].kind)
                }
            }
        }
    }

    func applyMinimumSize() {
        filter.minSizeBytes = Double(minSizeMB.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? Int64($0 * 1_048_576) : nil }
    }

    func toggle(_ link: GrabbedLink) {
        if selected.contains(link.url) { selected.remove(link.url) } else { selected.insert(link.url) }
    }

    func selectAllVisible(_ on: Bool) {
        if on { selected.formUnion(visible.map(\.url)) } else { selected.subtract(visible.map(\.url)) }
    }

    func toggleKind(_ kind: GrabKind) {
        if filter.kinds.contains(kind) { filter.kinds.remove(kind) } else { filter.kinds.insert(kind) }
    }

    func downloadSelected(into manager: DownloadManager) {
        let pageURL = RequestSecurity.webURL(from: pageURLString)
        for link in links where selected.contains(link.url) {
            let headers = session?.headers(for: link.url) ?? pageURL.map { ["Referer": $0.absoluteString] }
            manager.addDownload(url: link.url, suggestedName: link.name, headers: headers)
        }
    }
}

/// IDM's "Site Grabber": finds the files on a page (or a whole small site), lets you filter by type, name
/// and size, and adds the ones you pick to the download queue.
struct SiteGrabberView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var manager: DownloadManager
    @StateObject private var model = SiteGrabberModel()
    @ObservedObject private var store = SiteGrabberStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Site Grabber").font(.headline)
                if model.fromBrowser {
                    Label("Links from your browser", systemImage: "globe").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                TextField("Page address", text: $model.pageURLString)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.scan() }
                Picker("Look in", selection: $model.depth) {
                    Text("This page only").tag(0)
                    Text("Also linked pages (1 level)").tag(1)
                    Text("Also linked pages (2 levels)").tag(2)
                }
                .labelsHidden()
                .frame(width: 210)
                if model.isScanning {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Scan") { model.scan() }
                        .disabled(model.pageURLString.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !model.links.isEmpty { filterBar }

            if let error = model.errorText {
                Text(error).foregroundStyle(.red).font(.caption)
            } else if !model.statusText.isEmpty {
                HStack(spacing: 6) {
                    if model.isScanning { ProgressView().controlSize(.small) }
                    Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                }
            }

            List(model.visible) { link in
                HStack(spacing: 8) {
                    Image(systemName: model.selected.contains(link.url) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(model.selected.contains(link.url) ? Color.accentColor : .secondary)
                    Image(systemName: link.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
                    Text(link.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(link.size.map { ByteFormatter.string($0) } ?? "…")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    Text(link.url.host ?? "").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).frame(width: 140, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(link) }
            }
            .frame(minHeight: 240)

            HStack {
                Text("\(model.visible.count) shown" + (model.visible.count == model.links.count ? "" : " of \(model.links.count)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.visible.isEmpty {
                    let allSelected = model.visible.allSatisfy { model.selected.contains($0.url) }
                    Button(allSelected ? "Deselect All" : "Select All") { model.selectAllVisible(!allSelected) }
                }
                Button("Close") { model.stop(); isPresented = false }
                Button("Download Selected (\(model.selected.count))") {
                    model.downloadSelected(into: manager)
                    isPresented = false
                }
                .disabled(model.selected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 780, height: 600)
        .onAppear { takeSessionFromBrowser() }
        .onReceive(store.$session) { if $0 != nil { takeSessionFromBrowser() } }
    }

    /// Type chips, a name filter and a minimum size.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(GrabKind.allCases.filter { model.count(of: $0) > 0 }) { kind in
                    Toggle(isOn: Binding(get: { model.filter.kinds.contains(kind) }, set: { _ in model.toggleKind(kind) })) {
                        Label("\(kind.title) \(model.count(of: kind))", systemImage: kind.symbol)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }
            HStack {
                TextField("Name contains…", text: $model.filter.nameContains).textFieldStyle(.roundedBorder)
                TextField("Min size (MB)", text: $model.minSizeMB)
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                    .onChange(of: model.minSizeMB) { _ in model.applyMinimumSize() }
            }
        }
    }

    private func takeSessionFromBrowser() {
        guard let session = store.session else { return }
        model.load(session)
        store.session = nil
    }
}
