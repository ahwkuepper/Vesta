// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import VestaKit
import VestaDiagnostics

/// The popover. Structured as: what's the whole place doing → each room, its
/// scenes, then its individual lights. That order matches how often each is used,
/// not how complex each one is.
struct MenuBarView: View {
    @Bindable var model: AppModel
    /// Snapshot rendering needs a row already open to capture the expanded controls.
    var initialExpandedID: Light.ID? = nil
    /// Snapshot rendering wants the whole list, not a screen-sized window onto it.
    var rendersFullHeight = false
    @State private var expansion = Expansion()
    @State private var namingRoomID: Room.ID?
    /// The popover's window, used to measure how much room there is beneath the
    /// status item before deciding how tall to be.
    @State private var window: NSWindow?
    /// Natural height of the list, so a short list does not leave dead space below.
    @State private var measuredContent: Double = 0

    private var store: LightStore { model.store }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let message = store.availability.message {
                unavailable(message)
            } else if store.lights.isEmpty {
                empty
            } else {
                content
            }

            if let error = store.lastError {
                errorBanner(error)
            }
        }
        .frame(width: 330)
        .dynamicTypeClamped()
        .background(WindowReader { window = $0 })
        .task {
            if expansion.ids.isEmpty, let initial = initialExpandedID {
                expansion.open(initial, in: nil)
            }
            await model.start()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: store.anyLightOn ? "lightbulb.fill" : "lightbulb")
                .font(.appGlyph)
                .foregroundStyle(store.anyLightOn ? .yellow : .secondary)
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 1) {
                Text("Vesta").font(.appTitle)
                Text(summary)
                    .font(.appSummary)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Spacer()

            settingsMenu

            // One control for the thing people open this app to do.
            Toggle("", isOn: Binding(
                get: { store.anyLightOn },
                set: { store.toggleAll(on: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(store.commandableLights.isEmpty)
            .accessibilityLabel("All lights")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var summary: String {
        let commandable = store.commandableLights
        if commandable.isEmpty {
            return store.lights.isEmpty ? "No lights yet" : "\(store.lights.count) found, none paired"
        }
        let on = commandable.filter(\.state.isOn).count
        return on == 0 ? "All off" : "\(on) of \(commandable.count) on"
    }

    // MARK: - Body states

    /// How tall the popover may be, measured from the screen alone.
    ///
    /// Must not consult the popover's own frame: position would feed height, height
    /// would resize the popover, and NSPopover would reposition it again.
    private var maxAvailableHeight: Double {
        let screen = window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 900
        // Caps the scroll view, so reserve what sits around it: the header, the
        // divider and NSPopover's own padding. Only bites when there are enough
        // lamps to fill the screen.
        return max(260, visible - Self.chromeAllowance)
    }

    /// Header (~56) + divider + NSPopover padding, plus a little margin.
    private static let chromeAllowance: Double = 90

    /// The popover is exactly as tall as its contents, up to the room available.
    ///
    /// There is no resize handle. Menu-bar popovers on macOS are not resizable, and
    /// sizing to content means a handful of lamps needs no scrolling.
    private var contentHeight: Double {
        guard measuredContent > 0 else { return maxAvailableHeight }
        // Offscreen renders have no screen to be constrained by; clipping them to a
        // notional screen height truncates the shot mid-row.
        return rendersFullHeight ? measuredContent
                                 : min(measuredContent, maxAvailableHeight)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(store.rooms.enumerated()), id: \.element.id) { index, room in
                    if index > 0 {
                        Divider().padding(.horizontal, 14)
                    }
                    RoomSection(room: room, store: store,
                                expansion: $expansion, namingRoomID: $namingRoomID)
                }

                // Lights the bridge knows but has not put in a room. Showing them
                // beats silently dropping them.
                if !store.unroomedLights.isEmpty {
                    if !store.rooms.isEmpty { Divider().padding(.horizontal, 14) }
                    if !store.rooms.isEmpty {
                        Text("Not in a room")
                            .font(.sectionLabel)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 14)
                    }
                    ForEach(store.unroomedLights) { light in
                        LightRow(light: light, store: store, expansion: $expansion, roomID: nil)
                    }
                }

                if store.allLightsNeedPairing { pairingHint }
            }
            .padding(.vertical, 8)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: ContentHeightKey.self,
                                           value: geometry.size.height)
                }
            )
        }
        .onPreferenceChange(ContentHeightKey.self) { measuredContent = $0 }
        .frame(height: contentHeight, alignment: .top)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Says what went wrong, at the bottom where it cannot displace the controls.
    ///
    /// Clears itself after a few seconds and can be dismissed.
    private func errorBanner(_ error: UserFacingError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.messageBody)
                .foregroundStyle(.orange)
            Text(error.message)
                .font(.messageBody)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                store.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.controlGlyphBold)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .motion(.easeOut(duration: 0.18), value: error.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(error.message)")
    }

    /// The state Bluetooth mode is genuinely in. Saying so plainly beats showing
    /// dead controls and letting the user work out why nothing happens.
    private var pairingHint: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("These lights need pairing", systemImage: "lock.fill")
                .font(.messageTitle)
            Text("Vesta can see these bulbs over Bluetooth but can’t command them. "
                 + "Switch to Bridge in the gear menu — the bridge has no such limit.")
                .font(.messageBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.10)))
        .padding(.horizontal, 12)
    }

    private var empty: some View {
        // A Keychain read that failed is not "no lights yet": the bridge is paired
        // and the app simply cannot see the credential. Saying so beats an empty
        // list that looks like a first run.
        if let status = model.credentialFailure {
            return AnyView(unavailable(
                "Vesta can’t read your bridge credentials from the Keychain "
                + "(error \(status)). Your bridge is still paired — unlock your "
                + "login keychain, or re-pair if this persists."))
        }
        return AnyView(VStack(spacing: 8) {
            Image(systemName: "wifi.router")
                .font(.messageGlyph)
                .foregroundStyle(.secondary)
            Text("Looking for lights…")
                .font(.messageTitle)
            Text(model.mode == .bridge
                 ? "Connecting to your Hue Bridge."
                 : "Make sure your Hue bulbs are powered on and within Bluetooth range.")
                .font(.messageBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26))
    }

    /// Denying the permission prompt once is a dead end unless the app offers a way back.
    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.noticeGlyph)
                .foregroundStyle(.orange)
            Text(message)
                .font(.noticeBody)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if store.availability == .unauthorized {
                Button("Open Bluetooth Settings…") {
                    NSWorkspace.shared.open(URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    // MARK: - Footer

    /// Settings live behind a gear, the way Control Center and most menu-bar apps
    /// do it. The transport choice is a rare, one-time decision and does not deserve
    /// permanent space next to controls used every day.
    private var settingsMenu: some View {
        Menu {
            if model.availableModes.count > 1 {
                Picker("Connection", selection: Binding(
                    get: { model.mode },
                    set: { newMode in Task { await model.switchTo(newMode) } }
                )) {
                    ForEach(model.availableModes) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
            } else {
                Text("Connected via \(model.mode.title)")
                Divider()
            }

            Text("Not affiliated with Signify or Philips Hue")
                .font(.finePrint)
            Divider()

            Button("Copy Diagnostics") {
                let report = Diagnostics.report(store: store, mode: model.mode)
                // Local only: the general pasteboard syncs to the user's other
                // Apple devices via Universal Clipboard, which would send a report
                // about their home off the machine.
                NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
                NSPasteboard.general.setString(report, forType: .string)
                Log.ui.info("diagnostics copied to the pasteboard")
            }
            .help("Copies a health report — no light or room names, nothing sent anywhere")

            Divider()

            Button("Quit Vesta") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .font(.toolbarGlyph)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

/// Reports the natural height of the popover's content.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = max(value, nextValue())
    }
}
