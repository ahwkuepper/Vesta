// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import VestaBridge

/// First-run setup, shown in place of the light list when nothing is paired.
///
/// The physical button press is the authorisation step, so it gets its own screen
/// rather than a line of small print: a person has to walk to the bridge, and the
/// interface should be honest that it is asking them to.
struct PairingView: View {
    @Bindable var controller: PairingController
    var onPaired: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            switch controller.step {
            case .idle:            start
            case .searching:       searching
            case .choosing(let found): choose(found)
            case .pressButton(let host, let left): press(host: host, secondsLeft: left)
            case .paired:          done
            case .failed(let why): failed(why)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private var start: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.router")
                .font(.messageGlyph)
                .foregroundStyle(.secondary)
            Text("Set up your bridge")
                .font(.messageTitle)
            Text("Vesta controls your lights through the Hue Bridge on your network. "
                 + "Nothing leaves it.")
                .font(.messageBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Find my bridge") { controller.search() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
    }

    private var searching: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Looking for a bridge…")
                .font(.messageTitle)
            Text("macOS may ask for permission to find devices on your local network.")
                .font(.messageBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func choose(_ found: [BridgeDiscovery.Candidate]) -> some View {
        if found.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .font(.noticeGlyph)
                    .foregroundStyle(.secondary)
                Text("No bridge answered")
                    .font(.messageTitle)
                Text("Some networks block the discovery Vesta uses. "
                     + "Enter the bridge's address instead — the Hue app shows it "
                     + "under Settings.")
                    .font(.messageBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                manualEntry
                Button("Search again") { controller.search() }
                    .buttonStyle(.link)
                    .font(.messageBody)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "wifi.router")
                    .font(.messageGlyph)
                    .foregroundStyle(.secondary)
                Text(found.count == 1 ? "Found your bridge" : "Found \(found.count) bridges")
                    .font(.messageTitle)
                ForEach(found) { candidate in
                    Button {
                        controller.pair(host: candidate.host)
                    } label: {
                        Text(candidate.displayName)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                DisclosureGroup("Enter an address instead") { manualEntry }
                    .font(.messageBody)
                    .padding(.top, 2)
            }
        }
    }

    private var manualEntry: some View {
        HStack(spacing: 6) {
            // A plausible-looking address teaches the format better than a
            // documentation-range one does. Not a real address from anywhere.
            TextField("192.168.1.42", text: $controller.manualHost)  // check-no-secrets: allow
                .textFieldStyle(.roundedBorder)
                .font(.messageBody)
                .onSubmit { pairManually() }
            Button("Pair") { pairManually() }
                .disabled(controller.manualHost.isEmpty)
        }
        .padding(.top, 2)
    }

    private func pairManually() {
        let host = controller.manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        controller.pair(host: host)
    }

    private func press(host: String, secondsLeft: Int) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "button.programmable")
                .font(.messageGlyph)
                .foregroundStyle(.tint)
            Text("Press the button on your bridge")
                .font(.messageTitle)
            Text("The round button on top. That press is what authorises Vesta — "
                 + "there is no account and no code to type.")
                .font(.messageBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(secondsLeft)s")
                .font(.sectionValue)
                .foregroundStyle(.secondary)
            Button("Cancel") { controller.cancel() }
                .buttonStyle(.link)
                .font(.messageBody)
        }
    }

    private var done: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.messageGlyph)
                .foregroundStyle(.green)
            Text("Paired")
                .font(.messageTitle)
            Text("Vesta is pinned to this bridge's key from now on.")
                .font(.messageBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(900))
            onPaired()
        }
    }

    private func failed(_ why: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.noticeGlyph)
                .foregroundStyle(.orange)
            Text("Couldn’t pair")
                .font(.messageTitle)
            Text(why)
                .font(.messageBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { controller.search() }
                .buttonStyle(.borderedProminent)
        }
    }
}
