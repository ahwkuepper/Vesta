import SwiftUI
import AppKit
import VestaDesign
import VestaKit
import VestaUI

struct HomeView: View {
    @Bindable var model: HomeModel
    var maximumHeight: CGFloat = 700
    @State private var resettingOrder = false
    var body: some View {
        PopoverPage(maximumHeight: maximumHeight) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "house.fill").foregroundStyle(.secondary)
                    Text(model.settings ? "Connections" : "Home").font(.headline)
                    if !model.settings { Text("\(model.lightsOn) lights on").font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    if model.settings {
                        Button("Done") { model.settings = false; model.account = false; model.pairing = false }.controlSize(.small)
                    } else {
                        Menu {
                            Button("Connections & rooms…") { model.settings = true }
                            Button("Refresh all") { Task { await model.refresh() } }
                            Toggle("Use Celsius", isOn: $model.celsius)
                            Toggle("Smart room order", isOn: $model.smartOrder)
                            Menu("Room priority") {
                                ForEach(model.rooms.filter { $0 != "Unassigned" }, id: \.self) { room in
                                    Menu(room) {
                                        Picker("Priority", selection: Binding(
                                            get: { model.roomPriorities[room] ?? .automatic },
                                            set: { model.setPriority($0, room: room) }
                                        )) {
                                            ForEach(RoomPriority.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                        }
                                    }
                                }
                            }
                            Button("Reset learned order…") { resettingOrder = true }
                            Divider()
                            Button("Quit Vesta Home") { NSApp.terminate(nil) }.keyboardShortcut("q")
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Home settings")
                    }
                }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
                if !model.settings { ClimateSummary(model: model) }
                Divider().padding(.horizontal, 16)
            }
        } content: {
            VStack(spacing: 0) {
                if model.settings { ConnectionView(model: model) }
                else {
                    if model.climateExpanded { ClimateDetails(model: model) }
                    notices
                    navigation
                    rooms
                }
            }
        }
        .frame(width: MenuMetrics.width).dynamicTypeClamped()
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onChange(of: model.rooms) { model.reconcilePresentedRooms() }
        .confirmationDialog("Reset learned room order?", isPresented: $resettingOrder) {
            Button("Reset learned order", role: .destructive) { model.resetLearnedOrder() }
        } message: {
            Text("Clears this Mac’s usage summary. Your room and device preferences stay. The order updates next time you open Home.")
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.hueError { notice(error) }
            if let error = model.hue?.lastError { notice(error.message) }
            if let message = model.hue?.availability.message { notice(message) }
            if let error = model.kasa.error { notice(error) }
            if let error = model.localError { notice(error) }
        }.padding(.horizontal, 18)
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
    }
    private var navigation: some View {
        VStack(spacing: 12) {
            HStack {
                Button { model.allLights(true) } label: { Label("Lights on", systemImage: "lightbulb").chipMetrics().chipStyle() }
                Button { model.allLights(false) } label: { Label("All lights off", systemImage: "power").chipMetrics().chipStyle() }
                Spacer(minLength: 0)
            }.buttonStyle(.plain).chipGroup().disabled(model.devices.allSatisfy { !$0.reachable })
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a light or room", text: $model.search).textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.font(.subheadline).padding(8).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }
    private var rooms: some View {
        VStack(spacing: 6) {
            if model.devices.isEmpty {
                VStack(spacing: 8) {
                    if model.hueRefreshing || model.kasa.refreshing { ProgressView().controlSize(.small); Text("Finding your lights…") }
                    else { Text("No lights connected yet"); Button("Open connections") { model.settings = true } }
                }.font(.callout).foregroundStyle(.secondary).padding(24)
            } else if !model.rooms.contains(where: { !model.visible(in: $0).isEmpty }) {
                Text("No matching devices").foregroundStyle(.secondary).padding(24)
            }
            ForEach(model.orderedRooms, id: \.self) { room in
                let devices = model.visible(in: room)
                if !devices.isEmpty {
                    HStack(spacing: 7) {
                        Button {
                            if model.collapsed.contains(room) { model.collapsed.remove(room) } else { model.collapsed.insert(room) }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: roomSymbol(room)).frame(width: 17)
                                Text(room).font(.roomName).lineLimit(1)
                                Image(systemName: model.collapsed.contains(room) ? "chevron.right" : "chevron.down").font(.caption2)
                            }.foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel("\(model.collapsed.contains(room) ? "Expand" : "Collapse") \(room)")
                        Spacer()
                        let lights = model.devices.filter { $0.room == room && $0.kind == .light && $0.reachable }
                        if !lights.isEmpty {
                            Toggle("All lights in \(room)", isOn: Binding(get: { lights.contains { $0.isOn } }, set: { model.allLights($0, room: room) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                    }.padding(.horizontal, 18).padding(.top, 8)
                    if !model.collapsed.contains(room) {
                        if room == "Unassigned" {
                            Text("Open a device to choose its room.").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
                        }
                        hueScenes(room)
                        ForEach(devices) { HomeDeviceRow(model: model, device: $0) }
                    }
                    Divider().padding(.horizontal, 18).padding(.top, 4)
                }
            }
            Text("Hue & Kasa · Local network   /   Nest · Google")
                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.vertical, 12)
        }
    }
    @ViewBuilder private func hueScenes(_ room: String) -> some View {
        if let hue = model.hue, let hueRoom = hue.rooms.first(where: { $0.name == room }), !hue.scenes(in: hueRoom).isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(hue.scenes(in: hueRoom)) { scene in
                        Button { model.recordRoomUse(room); hue.recall(scene) } label: { Text(scene.name).chipMetrics().chipStyle(isActive: scene.isActive) }
                            .buttonStyle(.plain).help("Hue scene: \(scene.name)")
                    }
                }.chipGroup().padding(.horizontal, 18)
            }.scrollIndicators(.hidden).padding(.vertical, 4)
            Text("Hue scenes").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
        }
    }
    private func roomSymbol(_ name: String) -> String {
        let room = name.lowercased()
        if room.contains("bed") || room.contains("nursery") { return "bed.double" }
        if room.contains("living") { return "sofa" }
        if room.contains("kitchen") { return "refrigerator" }
        if room.contains("garage") { return "car" }
        if room.contains("office") { return "desktopcomputer" }
        return room == "unassigned" ? "square.dashed" : "door.left.hand.open"
    }
}

private struct HomeDeviceRow: View {
    @Bindable var model: HomeModel
    let device: HomeDevice
    @State private var colorExpanded = false
    var expanded: Bool { model.expanded.contains(device.id) }
    var enabled: Bool { device.reachable && !(device.kasaDevice.map { model.kasa.busy.contains($0.id) } ?? false) }
    var status: String {
        if !device.reachable { return device.status == "Ready" ? "Unavailable" : device.status }
        if device.isOn { return device.brightness.map { "\(Int($0))%" } ?? "On" }
        return "Off"
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                DeviceSwatch(color: device.color, isOn: device.isOn, ready: device.reachable, isPlug: device.kind == .device)
                Button {
                    if expanded { model.expanded.remove(device.id) } else { model.expanded.insert(device.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.lightName).foregroundStyle(.primary).lineLimit(1)
                            Text(status).font(.lightStatus).foregroundStyle(device.reachable ? Color.secondary : .orange)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(device.name), \(status). \(expanded ? "Hide" : "Show") controls")
                Toggle("\(device.name) power", isOn: Binding(get: { device.isOn }, set: { model.power(device, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(!enabled)
            }
            if expanded { controls }
        }.deviceRowSurface(expanded: expanded, animatesExpansion: false)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let brightness = device.brightness {
                GradientSlider(value: Binding(get: { brightness }, set: { model.brightness(device, $0) }), range: 1...100,
                    gradient: .brightness(of: device.color), label: "\(device.name) brightness",
                    format: { "\(Int($0)) percent" }, isEnabled: enabled && device.isOn)
            }
            if let warmth = device.warmth {
                HStack { Text("Warmth"); Spacer(); Text("\(Int(warmth)) K").monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                GradientSlider(value: Binding(get: { max(2500, warmth) }, set: { model.warmth(device, $0) }), range: 2500...6500,
                    gradient: .colorTemperature, label: "\(device.name) warmth", format: { "\(Int($0)) Kelvin" }, isEnabled: enabled && device.isOn)
            }
            if device.supportsColor {
                DisclosureGroup("Color", isExpanded: $colorExpanded) {
                    GradientSlider(value: Binding(get: {
                        NSColor(deviceRed: device.color.r, green: device.color.g, blue: device.color.b, alpha: 1).hueComponent * 360
                    }, set: { model.color(device, NSColor(hue: $0 / 360, saturation: 0.8, brightness: 1, alpha: 1)) }),
                        range: 0...360, gradient: .hue, label: "\(device.name) color",
                        format: { "\(Int($0)) degrees" }, isEnabled: enabled && device.isOn)
                }.font(.callout)
            }
            if let light = device.hueLight, !light.capabilities.effects.isEmpty {
                Picker("Effect", selection: Binding(get: { light.state.effect ?? "" }, set: { model.recordRoomUse(device.room); model.hue?.setEffect($0.isEmpty ? nil : $0, for: light.id) })) {
                    Text("None").tag("")
                    ForEach(light.capabilities.effects, id: \.self) { Text($0.capitalized).tag($0) }
                }.controlSize(.small).disabled(!enabled || !device.isOn)
            }
            Divider()
            Picker("Room", selection: Binding(get: { device.room }, set: { model.assign(device, room: $0) })) {
                ForEach(Array(Set(model.rooms + ["Unassigned"])).sorted(), id: \.self) { Text($0).tag($0) }
            }.controlSize(.small)
            if device.isPlug {
                Picker("Use as", selection: Binding(get: { device.kind }, set: { model.assign(device, kind: $0) })) {
                    ForEach(DeviceKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            Picker("Smart order", selection: Binding(get: { model.placements[device.id]?.attention ?? .automatic }, set: { model.setAttention($0, device: device) })) {
                ForEach(DeviceAttention.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.controlSize(.small)
            Text(RoomAttention.isBackground(device, placement: model.placements[device.id])
                 ? "Background: being on won’t raise this room. Your manual use still counts."
                 : "Everyday lights can raise their room while on. Automatic learns room order from your manual use.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(device.provider.rawValue).font(.caption2).foregroundStyle(.tertiary)
            if let kasaDevice = device.kasaDevice {
                DisclosureGroup("Schedules", isExpanded: Binding(get: { model.schedules.contains(device.id) }, set: {
                    if $0 { model.schedules.insert(device.id) } else { model.schedules.remove(device.id) }
                })) { model.kasa.scheduleView(for: kasaDevice) }
                    .font(.callout)
            }
        }
    }
}
