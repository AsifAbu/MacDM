import SwiftUI

/// IDM's "Site Grabber": scans a web page for links matching a file-type
/// filter and lets the user batch-add them all to the download queue.
struct SiteGrabberView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var manager: DownloadManager

    @State private var pageURLString: String = ""
    @State private var fileTypeFilter: String = "zip,pdf,mp3,mp4,dmg,pkg"
    @State private var isScanning = false
    @State private var foundLinks: [URL] = []
    @State private var selectedLinks: Set<URL> = []
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Site Grabber").font(.headline)
            Text("Scan a web page and download every file link matching your filter.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("Page URL", text: $pageURLString).textFieldStyle(.roundedBorder)
            TextField("File extensions (comma separated)", text: $fileTypeFilter).textFieldStyle(.roundedBorder)

            HStack {
                Button(isScanning ? "Scanning…" : "Scan Page") { scan() }
                    .disabled(isScanning || URL(string: pageURLString) == nil)
                if !foundLinks.isEmpty {
                    Button(selectedLinks.count == foundLinks.count ? "Deselect All" : "Select All") {
                        selectedLinks = selectedLinks.count == foundLinks.count ? [] : Set(foundLinks)
                    }
                }
                Spacer()
            }

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.caption)
            }

            List(foundLinks, id: \.self) { link in
                HStack {
                    Image(systemName: selectedLinks.contains(link) ? "checkmark.square.fill" : "square")
                        .onTapGesture { toggle(link) }
                    Text(link.lastPathComponent).lineLimit(1)
                    Spacer()
                    Text(link.absoluteString).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle(link) }
            }
            .frame(minHeight: 200)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Download Selected (\(selectedLinks.count))") { downloadSelected() }
                    .disabled(selectedLinks.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    private func toggle(_ link: URL) {
        if selectedLinks.contains(link) { selectedLinks.remove(link) } else { selectedLinks.insert(link) }
    }

    private func scan() {
        guard let pageURL = URL(string: pageURLString) else { return }
        isScanning = true
        errorText = nil
        foundLinks = []

        let extensions = Set(fileTypeFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })

        URLSession.shared.dataTask(with: pageURL) { data, _, error in
            DispatchQueue.main.async {
                isScanning = false
                guard let data = data, let html = String(data: data, encoding: .utf8) else {
                    errorText = error?.localizedDescription ?? "Could not read page."
                    return
                }
                foundLinks = extractLinks(from: html, baseURL: pageURL, extensions: extensions)
            }
        }.resume()
    }

    private func extractLinks(from html: String, baseURL: URL, extensions: Set<String>) -> [URL] {
        var results: [URL] = []
        let pattern = #"(?:href|src)=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match = match, let r = Range(match.range(at: 1), in: html) else { return }
            let raw = String(html[r])
            guard let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL else { return }
            let ext = (resolved.lastPathComponent as NSString).pathExtension.lowercased()
            if extensions.contains(ext), !results.contains(resolved) {
                results.append(resolved)
            }
        }
        return results
    }

    private func downloadSelected() {
        for link in selectedLinks {
            manager.addDownload(url: link)
        }
        isPresented = false
    }
}
