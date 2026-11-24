import SwiftUI

@main
struct PrimfoldApp: App {
    var body: some Scene {
        WindowGroup {
            PrimfoldView()
        }
    }
}

enum Workspace: String, CaseIterable, Identifiable {
    case world
    case creator

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .world: "World"
        case .creator: "Creator Tools"
        }
    }

    var symbol: String {
        switch self {
        case .world: "globe"
        case .creator: "cube.transparent"
        }
    }
}

struct PrimfoldView: View {
    // Keep navigation state above both columns so resizing preserves selection.
    @State private var selection: Workspace? = .world
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .detail

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $compactColumn
        ) {
            WorkspaceSidebar(selection: $selection)
        } detail: {
            WorkspaceDetail(workspace: selection ?? .world)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.teal)
    }
}

private struct WorkspaceSidebar: View {
    @Binding var selection: Workspace?

    var body: some View {
        List(selection: $selection) {
            Section("Workspace") {
                ForEach(Workspace.allCases) { workspace in
                    NavigationLink(value: workspace) {
                        Label {
                            Text(workspace.title)
                        } icon: {
                            Image(systemName: workspace.symbol)
                        }
                    }
                }
            }
            Section {
                Label("Offline", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                Text("An independent viewer for Second Life.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Primfold")
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 320)
    }
}

private struct WorkspaceDetail: View {
    let workspace: Workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                WorkspaceHeader(workspace: workspace)
                OfflineNotice()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(Text(workspace.title))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }
}

private struct WorkspaceHeader: View {
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: workspace.symbol)
                .font(.largeTitle)
                .foregroundStyle(.teal)
                .accessibilityHidden(true)
            Text(workspace == .world ? "Welcome to Primfold" : "Room to create")
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(workspace == .world
                 ? "Your Second Life workspace, ready to grow."
                 : "Creator tools are a long-term goal for Primfold.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OfflineNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Offline preview", systemImage: "wifi.slash")
                .font(.headline)
            Text("Grid login and world rendering are not available in this first version.")
                .foregroundStyle(.secondary)
            Text("Explore World and Creator Tools from the workspace menu.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}
