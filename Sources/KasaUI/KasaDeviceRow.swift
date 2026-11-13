// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import KasaKit
import VestaKit
import VestaDesign

struct KasaDeviceRow: View {
    let device: KasaDevice
    @Bindable var model: KasaModel
    @Binding var isExpanded: Bool
    var schedulesExpanded: Binding<Bool> = .constant(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var busy: Bool { model.busy.contains(device.id) }
    private var swatch: ColorScience.RGB {
        if device.supportsColor && device.colorTemperature == 0 {
            let rgb = NSColor(hue: Double(device.hue ?? 0) / 360,
                              saturation: Double(device.saturation ?? 0) / 100, brightness: 1, alpha: 1)
            return .init(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent)
        }
        return ColorScience.rgb(fromMireds: Int(1_000_000 / Double(max(2500, device.colorTemperature ?? 2700))))
    }
    private var temperature: Double {
        if case .temperature(let value) = model.controlDraft[device.id] { return Double(value) }
        return Double(max(2500, device.colorTemperature ?? 2700))
    }
    private var hue: Double {
        if case .color(let value, _) = model.controlDraft[device.id] { return Double(value) }
        return Double(device.hue ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DeviceSwatch(color: swatch, isOn: device.isOn, ready: device.canControl,
                             needsPairing: device.connection == .signInRequired, isPlug: !device.isBulb)
                    .motion(.easeOut(duration: 0.25), value: device.isOn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.lightName).lineLimit(1).help(device.name)
                    Text(status).font(device.connection == .signInRequired ? .lightStatusEmphasis : .lightStatus)
                        .foregroundStyle(statusColor)
                }
                Spacer(minLength: 6)
                if device.supportsColor || device.supportsTemperature {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: "slider.horizontal.3").font(.rowControl)
                            .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
                            .frame(width: 26, height: 26)
                            .background(isExpanded ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                        .help(isExpanded ? "Hide colour controls" : "Show colour controls")
                        .accessibilityLabel("\(isExpanded ? "Hide" : "Show") colour controls for \(device.name)")
                }
                Button {
                    // A native NSSlider and SwiftUI text animate their layout in
                    // different coordinate spaces as NSPopover resizes. Commit the
                    // disclosure in one nonanimated transaction, including any
                    // switch between the page's natural and scrolling layouts.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { schedulesExpanded.wrappedValue.toggle() }
                } label: {
                    Image(systemName: "clock").font(.rowControl)
                        .foregroundStyle(schedulesExpanded.wrappedValue ? Color.accentColor : .secondary)
                        .frame(width: 26, height: 26)
                        .background(schedulesExpanded.wrappedValue ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
                    .help(schedulesExpanded.wrappedValue ? "Hide schedules" : "Show schedules")
                    .accessibilityLabel("\(schedulesExpanded.wrappedValue ? "Hide" : "Show") schedules for \(device.name)")
                Toggle("", isOn: Binding(get: { device.isOn }, set: { model.command(.power($0), device: device) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(!device.canControl || busy).accessibilityLabel("\(device.name) power")
            }
            // Keep known controls in the layout while reconnecting. A refresh
            // changes availability, not the popover's height or slider positions.
            if let brightness = device.brightness {
                GradientSlider(value: Binding(
                    get: { Double(model.brightnessDraft[device.id] ?? brightness) },
                    set: { model.setBrightness(Int($0.rounded()), for: device) }),
                    range: 1...100, gradient: .brightness(of: swatch),
                    label: "\(device.name) brightness", format: { "\(Int($0)) percent" },
                    isEnabled: device.canControl && device.isOn && !busy)
            }
            if isExpanded { colorControls }
            if schedulesExpanded.wrappedValue {
                KasaScheduleView(device: device, model: model)
            }
        }
        .deviceRowSurface(expanded: isExpanded || schedulesExpanded.wrappedValue, animatesExpansion: false)
        .task(id: schedulesExpanded.wrappedValue) {
            if schedulesExpanded.wrappedValue { await model.loadSchedules(for: device) }
        }
        .contextMenu {
            Text(device.model)
            if !device.firmware.isEmpty { Text("Firmware \(device.firmware)") }
            Text(device.transport == .xor ? "Legacy local connection" : "Authenticated local connection")
        }
    }

    private var status: String {
        if busy { return "Updating…" }
        if device.canControl, device.isOn, let draft = model.brightnessDraft[device.id] { return "\(draft)%" }
        return device.status
    }
    private var statusColor: Color {
        switch device.connection {
        case .signInRequired: .orange
        case .offline: .red.opacity(0.85)
        default: .secondary
        }
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5)
            if device.supportsTemperature {
                labelled("Temperature", value: Formatting.kelvin(Int(temperature))) {
                    GradientSlider(value: Binding(get: { temperature }, set: { model.setControl(.temperature(Int($0.rounded())), for: device) }),
                                   range: 2500...6500,
                                   gradient: Gradient(colors: stride(from: 2500.0, through: 6500.0, by: 250).map {
                                       Color(ColorScience.rgb(fromMireds: Int(1_000_000 / $0))) }),
                                   label: "\(device.name) colour temperature", format: { Formatting.kelvin(Int($0)) },
                                   isEnabled: device.canControl && device.isOn && !busy)
                }
                HStack(spacing: 5) {
                    ForEach([2700, 3000, 4000, 6500], id: \.self) { kelvin in
                        let active = device.isOn && device.colorTemperature == kelvin
                        Button { model.command(.temperature(kelvin), device: device) } label: {
                            Text(Formatting.kelvin(kelvin)).chipMetrics().chipStyle(isActive: active).contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Set \(device.name) to \(kelvin) kelvin")
                        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                    }
                    Spacer(minLength: 0)
                }.chipGroup(spacing: 5).disabled(!device.canControl || !device.isOn || busy)
            }
            if device.supportsColor {
                labelled("Colour", value: "\(Int(hue))°") {
                    GradientSlider(value: Binding(get: { hue }, set: { model.setControl(.color(hue: Int($0.rounded()), saturation: 90), for: device) }),
                                   range: 0...360, gradient: .hue, label: "\(device.name) colour",
                                   format: { "hue \(Int($0)) degrees" }, isEnabled: device.canControl && device.isOn && !busy)
                }
            }
        }
        .transition(.asymmetric(insertion: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.16)), removal: .identity))
    }

    private func labelled<Content: View>(_ title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title.uppercased()).font(.sectionLabel).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.sectionValue).foregroundStyle(.secondary)
            }
            content()
        }
    }
}
