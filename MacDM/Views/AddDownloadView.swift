import SwiftUI
import AppKit

struct AddDownloadView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var manager: DownloadManager

    @State private var urlString: String = ""
    @State private var fileName: String = ""
    @State private var destinationFolder: URL
    @State private var startImmediately: Bool = true
    @State private var errorText: String?

    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
        self._destinationFolder = State(initialValue: DownloadManager.shared.defaultDownloadFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Download").font(.headline)

            TextField("File URL (http:// or https://)", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .onChange(of: urlString) { newValue in
                    if let url = URL(string: newValue), fileName.isEmpty {
                        fileName = url.lastPathComponent
                    }
                }

            TextField("Save as (optional)", text: $fileName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Save to:")
                Text(destinationFolder.path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFolder() }
            }

            Toggle("Start downloading immediately", isOn: $startImmediately)

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add Download") { addDownload() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(URL(string: urlString) == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string), let url = URL(string: clip),
               url.scheme == "http" || url.scheme == "https" {
                urlString = clip
                fileName = url.lastPathComponent
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            destinationFolder = url
        }
    }

    private func addDownload() {
        guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else {
            errorText = "Enter a valid http(s) URL."
            return
        }
        let task = manager.addDownload(url: url, suggestedName: fileName.isEmpty ? nil : fileName, startImmediately: startImmediately)
        task.destinationFolder = destinationFolder
        isPresented = false
    }
}
