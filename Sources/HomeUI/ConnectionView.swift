import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VestaUI
import NestCore

struct ConnectionView: View {
    @Bindable var model: HomeModel
    @State private var redirect = ""
    @State private var project = ""
    @State private var importing = false
    @State private var importingLayout = false
    @State private var exportingLayout = false
    @State private var layoutDocument: HomeLayoutDocument?
    @State private var layoutMessage: String?
    @State private var authorizing = false
    @State private var waitingForRedirect = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.pairing {
                HomePairingView { model.pairing = false; Task { await model.reconnectedHue() } }
                Button("Back") { model.pairing = false }
            } else if model.account {
                model.kasa.accountView { model.account = false }
            } else {
                section("Philips Hue", symbol: "lightbulb") {
                    Text(model.hue == nil ? "Use your saved Vesta pairing, or connect a bridge." : "\(model.hue?.lights.count ?? 0) lights · Hue rooms and scenes")
                    if let error = model.hueError { Text(error).foregroundStyle(.orange) }
                    HStack {
                        Button("Retry saved pairing") { Task { await model.reconnectedHue() } }.disabled(model.hueRefreshing)
                        Button("Pair bridge…") { model.pairing = true }
                    }
                }
                section("Kasa", symbol: "powerplug") {
                    Text("\(model.kasa.devices.count) devices · \(model.kasa.signedIn ? "Sign-in saved" : "No saved sign-in")")
                    if let error = model.kasa.error { Text(error).foregroundStyle(.orange) }
                    HStack {
                        Button("Account…") { model.account = true }
                        Button("Find devices") { Task { await model.kasa.refresh() } }.disabled(model.kasa.refreshing)
                    }
                }
                section("Nest", symbol: "thermometer.medium") {
                    Text(model.thermostat == nil ? "Optional: connect Nest using your own Google project." : "Connected through Google")
                    if let setupURL = URL(string: "https://github.com/ahwkuepper/Vesta/blob/main/home/SETUP.md") {
                        Link("Nest setup guide", destination: setupURL)
                    }
                    if let error = model.nestError { Text(error).foregroundStyle(.orange) }
                    HStack {
                        Button("Refresh") { Task { await model.refreshNest(force: true) } }.disabled(model.nestBusy || model.nestCommandBusy || model.targetDraft != nil || model.nestRetryAt != nil || authorizing)
                        Button("Authorize…", action: authorize).disabled(model.nestBusy || model.nestCommandBusy || model.targetDraft != nil || model.nestRetryAt != nil || authorizing)
                    }
                    if waitingForRedirect {
                        Text("After approving access in Google, paste the complete returned Google URL here.")
                        SecureField("Returned URL", text: $redirect).textFieldStyle(.roundedBorder)
                        Button("Finish connection", action: connect).disabled(redirect.isEmpty || authorizing)
                    }
                    DisclosureGroup("Set up Nest") {
                        TextField("Device Access project ID", text: $project).textFieldStyle(.roundedBorder)
                        Button("Import OAuth client JSON…") { importingLayout = false; importing = true }.disabled(UUID(uuidString: project) == nil || authorizing)
                        Text("Uses the client file downloaded from Google Cloud. Secrets are stored in Keychain.")
                    }
                }
                section("Rooms", symbol: "rectangle.3.group") {
                    Text("Hue rooms appear automatically. Open any device to assign its room or classify a plug as a light. Assignments apply in Vesta Home.")
                    Toggle("Smart room order", isOn: $model.smartOrder)
                    Text("Everyday lights that are on come first, then rooms you used recently. Garage and storage rooms start low; repeated manual use can raise them. Choose Room priority in the Home settings menu to keep a room low. Ordering updates when you reopen Home, so controls stay still while you use them.")
                    Text("Learning uses a small summary of your actions in Home, stored only on this Mac. Timers, polling and All lights actions don’t count. Turning smart order off pauses learning.")
                    HStack {
                        TextField("New room name", text: $model.roomDraft).textFieldStyle(.roundedBorder).onSubmit { model.addRoom() }
                        Button("Add") { model.addRoom() }.disabled(model.roomDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !model.savedRooms.isEmpty { Text(model.savedRooms.joined(separator: ", ")).foregroundStyle(.secondary) }
                    HStack {
                        Button("Export layout…") {
                            do { layoutDocument = HomeLayoutDocument(data: try model.exportLayout()); exportingLayout = true }
                            catch { layoutMessage = error.localizedDescription }
                        }
                        Button("Import layout…") { importingLayout = true; importing = true }
                    }
                    Text("Transfer rooms, plug classifications and units to your other Macs. Credentials stay in Keychain. Imported assignments replace matching local assignments.")
                    if let layoutMessage { Text(layoutMessage).accessibilityAddTraits(.updatesFrequently) }
                }
                Text("Hue and Kasa connect on your local network. Nest uses Google’s cloud. Saved credentials are stored in this Mac’s Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).controlSize(.small)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if importingLayout {
                    do {
                        let file = try FileHandle(forReadingFrom: url)
                        defer { try? file.close() }
                        let data = try file.read(upToCount: HomeLayoutFile.byteLimit + 1) ?? Data()
                        try model.importLayout(data); layoutMessage = "Layout imported."
                    } catch { layoutMessage = error.localizedDescription }
                    return
                }
                do {
                    let credentials = try Credentials.imported(readInputFile(url.path), projectID: project)
                    Task {
                        do { try await model.nest.setup(credentials); model.nestError = nil }
                        catch { model.nestError = error.localizedDescription }
                    }
                } catch { model.nestError = error.localizedDescription }
            }
            .fileExporter(isPresented: $exportingLayout, document: layoutDocument, contentType: .json, defaultFilename: "Vesta Home Layout") { result in
                switch result {
                case .success: layoutMessage = "Layout exported. It contains room names and device identifiers; keep it private."
                case .failure(let error): layoutMessage = error.localizedDescription
                }
                layoutDocument = nil
            }
            .onDisappear { redirect = "" }
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.headline)
            content().font(.caption).fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, 5)
        }
    }
    private func authorize() {
        authorizing = true; model.nestBusy = true
        Task {
            defer { authorizing = false; model.nestBusy = false }
            do {
                let url = try await model.nest.authorizationURL()
                guard NSWorkspace.shared.open(url) else { model.nestError = "Couldn’t open your browser. Try again."; return }
                waitingForRedirect = true; model.nestError = nil
            } catch { model.nestError = error.localizedDescription }
        }
    }
    private func connect() {
        guard !model.nestBusy, !model.nestCommandBusy else { return }
        authorizing = true; model.nestBusy = true
        let value = redirect; redirect = ""
        Task {
            defer { authorizing = false; model.nestBusy = false }
            do { model.nestReadings = try await model.nest.connect(redirect: value); model.nestError = nil; waitingForRedirect = false }
            catch { model.nestError = error.localizedDescription }
        }
    }
}
