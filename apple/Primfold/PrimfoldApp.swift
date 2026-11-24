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
    // Keep navigation and the simulator session above both columns.
    @State private var selection: Workspace? = .world
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @State private var session = WorldSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $compactColumn
        ) {
            WorkspaceSidebar(selection: $selection, session: session)
        } detail: {
            WorkspaceDetail(workspace: selection ?? .world, session: session)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.teal)
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends UDP work in the background; explicitly leave the region.
            if phase == .background {
                Task { await session.signOut() }
            }
        }
    }
}

private struct WorkspaceSidebar: View {
    @Binding var selection: Workspace?
    let session: WorldSession

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
                Label {
                    Text(session.phase.title)
                } icon: {
                    Image(systemName: session.phase == .online ? "wifi" : "wifi.slash")
                }
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
    let session: WorldSession

    var body: some View {
        Group {
            if workspace == .world {
                if session.phase == .online || session.phase == .disconnecting {
                    ConnectedWorldView(session: session)
                } else {
                    WorldLoginView(session: session)
                }
            } else {
                CreatorPlaceholderView()
            }
        }
        .navigationTitle(Text(workspace.title))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }
}

private struct CreatorPlaceholderView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "cube.transparent")
                    .font(.largeTitle)
                    .foregroundStyle(.teal)
                    .accessibilityHidden(true)
                Text("Room to create")
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("Creator tools are a long-term goal for Primfold.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Building and editing world objects are not available yet.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
