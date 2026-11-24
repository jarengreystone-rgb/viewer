import SwiftUI

struct WorldLoginView: View {
    let session: WorldSession
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var grid = Grid.secondLife
    @State private var start = "last"
    @State private var agreeToTerms = false

    var body: some View {
        Form {
            Section {
                Text("Sign in to Second Life")
                    .font(.title2.bold())
                Text("Connect your avatar to a region using your account username, not your display name or email address.")
                    .foregroundStyle(.secondary)
            }
            Section("Account") {
                TextField("Username (first.last or first)", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                TextField("Authentication code (if required)", text: $token)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                Picker("Grid", selection: $grid) {
                    ForEach(Grid.allCases) { grid in
                        Text(grid.title).tag(grid)
                    }
                }
                Picker("Start at", selection: $start) {
                    Text("Last location").tag("last")
                    Text("Home").tag("home")
                }
            }
            .disabled(session.phase != .offline)

            Section {
                if let termsURL = URL(string: "https://www.lindenlab.com/legal/second-life-terms-and-conditions") {
                    Link("Read Second Life’s Terms of Service", destination: termsURL)
                }
                Toggle("I agree to Second Life’s Terms of Service", isOn: $agreeToTerms)
                    .disabled(session.phase != .offline)
            }

            Section {
                if let error = session.errorMessage {
                    Label {
                        Text(error).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("loginError")
                }
                if session.phase.isBusy {
                    HStack {
                        ProgressView()
                        Text(session.phase.title)
                    }
                    Button("Cancel", role: .cancel) {
                        session.cancelSignIn()
                    }
                    .disabled(session.phase == .disconnecting)
                } else {
                    Button("Sign In") { signIn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || password.isEmpty || !agreeToTerms)
                        .accessibilityIdentifier("signInButton")
                }
            } footer: {
                Text("Passwords and authentication codes are used for this sign-in only and are never saved.")
            }

            Section("Early connected version") {
                Text("This version supports a single region, nearby chat, short walking steps, and a 3D view of live object bounds.")
                Text("Terrain, textures, mesh shapes, avatar appearance, inventory, teleporting, and region crossings are not supported yet.")
                    .foregroundStyle(.secondary)
                Text("Signing in here may disconnect another viewer using the same account.")
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            password = ""
            token = ""
        }
    }

    private func signIn() {
        let credentials = LoginCredentials(username: username, password: password,
                                           token: token, start: start, grid: grid,
                                           agreeToTerms: agreeToTerms)
        session.signIn(credentials)
        password = ""
        token = ""
    }
}

struct ConnectedWorldView: View {
    let session: WorldSession
    @State private var showingChat = false

    var body: some View {
        VStack(spacing: 0) {
            WorldConnectionHeader(session: session)
            WorldSceneView(session: session)
                .frame(minHeight: 240)
                .overlay(alignment: .topLeading) {
                    Text("Simplified live view")
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                }
            WorldMovementControls(session: session)
            Text("Live bounds only. Terrain, textures, mesh shapes, and avatar appearance are not rendered.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Nearby Chat", systemImage: "bubble.left.and.bubble.right") {
                    showingChat = true
                }
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await session.signOut() }
                }
                .disabled(session.phase == .disconnecting)
            }
        }
        .sheet(isPresented: $showingChat) {
            NearbyChatView(session: session)
        }
    }
}

private struct WorldConnectionHeader: View {
    let session: WorldSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.regionName.isEmpty ? session.accountName : session.regionName)
                .font(.headline)
            Text(session.accountName).font(.subheadline)
            Text("\(Int(session.position.x)), \(Int(session.position.y)), \(Int(session.position.z)) · \(session.objectCount) objects")
                .font(.caption)
                .foregroundStyle(.secondary)
            if session.phase == .disconnecting { Text(session.phase.title) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

private struct WorldMovementControls: View {
    let session: WorldSession

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                turnLeft
                backward
                forward
                turnRight
            }
            VStack {
                HStack { turnLeft; turnRight }
                HStack { backward; forward }
            }
        }
        .buttonStyle(.bordered)
        .disabled(session.phase != .online)
        .padding()
    }

    private var turnLeft: some View {
        Button("Turn Left", systemImage: "arrow.turn.up.left") { session.turn(.pi / 8) }
    }
    private var turnRight: some View {
        Button("Turn Right", systemImage: "arrow.turn.up.right") { session.turn(-.pi / 8) }
    }
    private var forward: some View {
        Button("Step Forward", systemImage: "arrow.up") { session.step(forward: true) }
    }
    private var backward: some View {
        Button("Step Back", systemImage: "arrow.down") { session.step(forward: false) }
    }
}

private struct NearbyChatView: View {
    let session: WorldSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack {
                List(session.messages) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.sender).font(.headline)
                        Text(message.text).textSelection(.enabled)
                    }
                }
                if session.messages.isEmpty {
                    Text("Nearby chat will appear here.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Say something nearby", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                    Button("Send", systemImage: "paperplane") {
                        session.sendChat(draft)
                        draft = ""
                    }
                    .disabled(session.phase != .online
                              || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || draft.utf8.count > 1023)
                }
                .padding()
                if draft.utf8.count > 1023 {
                    Text("Message is too long. Use at most 1,023 UTF-8 bytes.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Nearby Chat")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
