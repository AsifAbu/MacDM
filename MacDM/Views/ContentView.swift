import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: DownloadManager
    @EnvironmentObject var clipboardMonitor: ClipboardMonitor
    @State private var selectedCategory: DownloadCategory? = nil
    @State private var selectedStatus: DownloadStatus? = nil
    @State private var searchQuery: String = ""
    @State private var showAddSheet = false
    @State private var showSiteGrabber = false
    @State private var selectedTask: DownloadTask?

    var filteredTasks: [DownloadTask] {
        var result = manager.searchTasks(searchQuery)
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }
        if let status = selectedStatus {
            result = result.filter { $0.status == status }
        }
        return result
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedCategory: $selectedCategory, selectedStatus: $selectedStatus)
        } detail: {
            VStack(spacing: 0) {
                ToolbarView(showAddSheet: $showAddSheet, showSiteGrabber: $showSiteGrabber, searchQuery: $searchQuery)
                Divider()
                if filteredTasks.isEmpty {
                    EmptyStateView(showAddSheet: $showAddSheet)
                } else {
                    // A plain scrolling stack rather than List: List's table measures a new row once, while it is
                    // still short, and keeps that height when the progress bar appears (the row showed half).
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredTasks) { task in
                                DownloadRowView(task: task)
                                    .padding(.horizontal, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selectedTask == task ? Color.accentColor.opacity(0.18) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedTask = task }
                                Divider().padding(.leading, 56)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddDownloadView(isPresented: $showAddSheet)
                .environmentObject(manager)
        }
        .sheet(isPresented: $showSiteGrabber) {
            SiteGrabberView(isPresented: $showSiteGrabber)
                .environmentObject(manager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddDownloadSheet)) { _ in
            showAddSheet = true
        }
        // Links sent from the browser open the Site Grabber.
        .onReceive(SiteGrabberStore.shared.$session) { session in
            if session != nil { showSiteGrabber = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardLinkDetected)) { note in
            if let url = note.object as? URL {
                clipboardMonitor.pendingURL = url
                clipboardMonitor.showPrompt = true
            }
        }
        .alert("Download link detected", isPresented: $clipboardMonitor.showPrompt, presenting: clipboardMonitor.pendingURL) { url in
            Button("Download") { manager.addDownload(url: url) }
            Button("Ignore", role: .cancel) {}
        } message: { url in
            Text(url.absoluteString)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var manager: DownloadManager
    @Binding var selectedCategory: DownloadCategory?
    @Binding var selectedStatus: DownloadStatus?

    var body: some View {
        List {
            Section("Status") {
                sidebarRow(title: "All Downloads", count: manager.tasks.count, isSelected: selectedStatus == nil && selectedCategory == nil) {
                    selectedStatus = nil; selectedCategory = nil
                }
                ForEach(DownloadStatus.allCases, id: \.self) { status in
                    let count = manager.tasks.filter { $0.status == status }.count
                    sidebarRow(title: status.rawValue.capitalized, count: count, isSelected: selectedStatus == status) {
                        selectedStatus = status; selectedCategory = nil
                    }
                }
            }
            Section("Categories") {
                ForEach(DownloadCategory.allCases, id: \.self) { category in
                    let count = manager.tasks.filter { $0.category == category }.count
                    sidebarRow(title: category.folderName, count: count, isSelected: selectedCategory == category) {
                        selectedCategory = category; selectedStatus = nil
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    @ViewBuilder
    private func sidebarRow(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

struct ToolbarView: View {
    @EnvironmentObject var manager: DownloadManager
    @Binding var showAddSheet: Bool
    @Binding var showSiteGrabber: Bool
    @Binding var searchQuery: String

    var body: some View {
        HStack {
            Button { showAddSheet = true } label: {
                Label("Add URL", systemImage: "plus.circle.fill")
            }
            Button { showSiteGrabber = true } label: {
                Label("Site Grabber", systemImage: "magnifyingglass.circle")
            }
            Button { manager.resumeAll() } label: {
                Label("Resume All", systemImage: "play.fill")
            }
            Button { manager.pauseAll() } label: {
                Label("Pause All", systemImage: "pause.fill")
            }
            Spacer()
            TextField("Search downloads…", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
        .padding(10)
    }
}

struct EmptyStateView: View {
    @Binding var showAddSheet: Bool
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No downloads yet")
                .font(.title3)
            Button("Add a Download") { showAddSheet = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
