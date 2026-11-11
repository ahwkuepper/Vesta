// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import ServiceManagement
import KasaKit
import VestaDesign

struct KasaMenuView: View {
    @Bindable var model: KasaModel
    @State var accountOpen = false
    @State private var expandedIDs: Set<String> = []
    @State var scheduleIDs: Set<String> = []
    var snapshot = false

    // Set by the status-item host before showing, not inferred from the popover
    // after AppKit has already chosen a placement. The default is for previews.
    var availableHeight: CGFloat = 600
    private var bulbs: [KasaDevice] { model.devices.filter(\.isBulb) }

    var body: some View {
        PopoverPage(maximumHeight: availableHeight, fullHeight: snapshot) {
            VStack(spacing: 0) { header; Divider() }
        } content: {
            VStack(spacing: 0) {
                if accountOpen {
                    KasaAccountView(model: model) { accountOpen = false }
                } else if model.devices.isEmpty {
                    empty
                } else {
                    deviceList
                }
                if let error = model.error { errorBanner(error) }
            }
        }
        .frame(width: MenuMetrics.width)
        .dynamicTypeClamped()
        .task { if !snapshot { await model.start() } }
    }

    private var header: some View {
        MenuHeader(title: "Vesta Kasa", summary: model.summary,
                   symbol: model.anyOn ? "powerplug.fill" : "powerplug", isOn: model.anyOn) {
            settingsMenu
            Toggle("", isOn: Binding(
                get: { bulbs.contains { $0.canControl && $0.isOn } },
                set: { on in
                    for bulb in bulbs where bulb.canControl { model.command(.power(on), device: bulb) }
                }
            ))
            .toggleStyle(.switch).labelsHidden()
            .disabled(!bulbs.contains(where: \.canControl))
            .accessibilityLabel("All lights")
            .help("Switch all bulbs; plugs keep their individual settings")
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.devices.count > 8 {
                TextField("Find a device", text: $model.search)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 14)
                    .accessibilityLabel("Find a device")
            }
            if !model.lights.isEmpty { section("Lights", devices: model.lights, symbol: "lightbulb") }
            if !model.plugs.isEmpty {
                if !model.lights.isEmpty { Divider().padding(.horizontal, 14) }
                section("Plugs", devices: model.plugs, symbol: "powerplug")
            }
            if model.filtered.isEmpty {
                Text("No matching devices").font(.messageBody).foregroundStyle(.secondary).padding(20)
            }
            if model.requiresSignIn {
                VStack(alignment: .leading, spacing: 5) {
                    Label("These devices need a sign-in", systemImage: "lock.fill").font(.messageTitle)
                    Text("Connect your Kasa account to control newer plugs and bulbs.")
                        .font(.messageBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Connect Kasa account…") { accountOpen = true }.controlSize(.small)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
    }

    private func section(_ title: String, devices: [KasaDevice], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.roomIcon).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.roomName).lineLimit(1)
                Text("\(devices.filter { $0.isOn && $0.canControl }.count)/\(devices.count)")
                    .font(.roomCount).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
            }
            .padding(.horizontal, 18)
            ForEach(devices) { device in
                KasaDeviceRow(device: device, model: model, isExpanded: Binding(
                    get: { expandedIDs.contains(device.id) },
                    set: { if $0 { expandedIDs.insert(device.id) } else { expandedIDs.remove(device.id) } }),
                    schedulesExpanded: Binding(
                        get: { scheduleIDs.contains(device.id) },
                        set: { if $0 { scheduleIDs.insert(device.id) } else { scheduleIDs.remove(device.id) } }))
            }
        }
        .padding(.top, 4).padding(.bottom, 6)
    }

    private var settingsMenu: some View {
        Menu {
            Button(model.isRefreshing ? "Refreshing devices…" : "Refresh devices", systemImage: "arrow.clockwise") {
                Task { await model.refresh(discover: true) }
            }.disabled(model.isRefreshing || model.isSigningIn).keyboardShortcut("r")
            Button(model.signedIn ? "Kasa account…" : "Sign in to Kasa…", systemImage: "person.crop.circle") { accountOpen = true }
            Divider()
            Button(SMAppService.mainApp.status == .enabled ? "Stop opening at login" : "Open at login") {
                do {
                    if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                    else { try SMAppService.mainApp.register() }
                } catch { model.error = "The login setting couldn’t be changed. Check System Settings → Login Items." }
            }
            Divider()
            Text("Independent app for TP-Link Kasa devices")
            Button("Quit Vesta Kasa") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: { Image(systemName: "gearshape").font(.toolbarGlyph) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
        .help("Settings").accessibilityLabel("Settings")
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.router").font(.messageGlyph).foregroundStyle(.secondary)
            Text(model.isRefreshing ? "Looking for devices…" : "Your Kasa home starts here").font(.messageTitle)
            Text("Connect to the same Wi-Fi as your Kasa plugs and lights. They’ll appear here automatically.")
                .font(.messageBody).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Find devices") { Task { await model.refresh(discover: true) } }
                .controlSize(.small).disabled(model.isRefreshing)
        }.padding(.horizontal, 24).padding(.vertical, 26)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.messageBody).foregroundStyle(.orange)
            Text(message).font(.messageBody).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { model.error = nil } label: {
                Image(systemName: "xmark").font(.controlGlyphBold).foregroundStyle(.secondary)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12)).overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine).accessibilityLabel("Error: \(message)")
    }
}
