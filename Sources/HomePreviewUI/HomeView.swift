import SwiftUI
import AppKit
import VestaDesign
import VestaKit

struct HomeView: View {
    @Bindable var model: HomeModel
    let layout: HomeLayout
    var maximumHeight: CGFloat = 640
    var compare: (() -> Void)?
    var choose: (HomeLayout) -> Void = { _ in }

    var body: some View {
        PopoverPage(maximumHeight: maximumHeight) {
            VStack(spacing: 0) {
                header
                ClimateSummary(model: model)
                Divider().padding(.horizontal, 16)
            }
        } content: {
            VStack(spacing: 0) {
                if model.climateExpanded { ClimateDetails(model: model) }
                navigation
                switch layout {
                case .favorites: favorites
                case .rooms: rooms
                case .tabs: tabs
                }
                Text("Interactive preview · Sample devices")
                    .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 14)
            }
        }
        .frame(width: MenuMetrics.width)
        .dynamicTypeClamped()
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "house.fill").foregroundStyle(.secondary)
            Text("Home").font(.headline)
            Text("\(model.lightsOn) lights on").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text("Preview").font(.caption2).foregroundStyle(.secondary)
            Menu {
                Picker("Menu layout", selection: Binding(get: { model.selectedLayout }, set: { model.selectedLayout = $0; choose($0) })) {
                    ForEach(HomeLayout.allCases) { Text($0.title).tag($0) }
                }
                if let compare { Button("Compare layouts…", action: compare) }
                Button("Reset preview") { model.reset() }
                Divider()
                Text("Preview — controls use sample data")
                Button("Quit Vesta Home Preview") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis.circle").font(.callout) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Home settings")
        }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
    }

    private var navigation: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(["Evening", "Bright", "All off"], id: \.self) { name in
                    Button { model.scene(name) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: name == "Evening" ? "moon" : name == "Bright" ? "sun.max" : "power")
                            Text(name)
                        }.chipMetrics().chipStyle(isActive: model.activeScene == name)
                    }.buttonStyle(.plain).help("\(name) for all lights in this preview")
                }
                Spacer(minLength: 0)
            }.chipGroup()
            if layout == .tabs {
                Picker("Show", selection: $model.selectedTab) {
                    Text("Lights").tag(HomeCategory.lights)
                    Text("Devices").tag(HomeCategory.devices)
                }.pickerStyle(.segmented)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a light or room", text: $model.search)
                    .textFieldStyle(.plain).accessibilityLabel("Find a device or room")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }.font(.subheadline).padding(8).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
    }

    private var favorites: some View {
        VStack(spacing: 4) {
            let starred = model.filtered(model.devices.filter(\.favorite))
            if !starred.isEmpty {
                label("Favorites", symbol: "star", count: nil)
                rows(starred, showRoom: true)
                Divider().padding(.horizontal, 18).padding(.vertical, 6)
            }
            let remaining = model.filtered(model.lights.filter { !$0.favorite })
            label("Other lights", symbol: "lightbulb", count: remaining.count)
            rows(remaining, showRoom: true)
            let others = model.filtered(model.otherDevices.filter { !$0.favorite })
            if !others.isEmpty {
                Divider().padding(.horizontal, 18).padding(.vertical, 6)
                label("Other devices", symbol: "powerplug", count: others.count)
                rows(others, showRoom: true)
            }
        }
    }

    private var rooms: some View {
        VStack(spacing: 6) {
            ForEach(model.rooms, id: \.self) { room in
                let devices = model.filtered(model.devices.filter { $0.room == room })
                if !devices.isEmpty {
                    HStack(spacing: 6) {
                        Button {
                            if model.collapsedRooms.contains(room) { model.collapsedRooms.remove(room) }
                            else { model.collapsedRooms.insert(room) }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: roomSymbol(room)).frame(width: 17)
                                Text(room).font(.roomName)
                                Image(systemName: model.collapsedRooms.contains(room) ? "chevron.right" : "chevron.down")
                                    .font(.caption2)
                            }.foregroundStyle(.secondary).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("\(model.collapsedRooms.contains(room) ? "Expand" : "Collapse") \(room)")
                        Spacer()
                        let lights = model.lights.filter { $0.room == room && $0.reachable }
                        if !lights.isEmpty {
                            Toggle("", isOn: Binding(get: { lights.contains(where: \.isOn) }, set: { model.toggleAll($0, room: room) }))
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                .accessibilityLabel("All lights in \(room)")
                        }
                    }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 2)
                    if !model.collapsedRooms.contains(room) { rows(devices, showRoom: false) }
                    Divider().padding(.horizontal, 18).padding(.top, 4)
                }
            }
            if model.filtered(model.devices).isEmpty { empty }
        }
    }

    private var tabs: some View {
        VStack(spacing: 4) {
            HStack {
                Picker("Room", selection: $model.selectedRoom) {
                    Text("All rooms").tag("All rooms")
                    ForEach(model.rooms, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().fixedSize().controlSize(.small)
                Spacer()
                Text(model.selectedTab == .lights ? "\(model.lights.count) lights" : "\(model.otherDevices.count) devices")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.bottom, 4)
            rows(model.filtered(model.devices.filter {
                $0.category == model.selectedTab && (model.selectedRoom == "All rooms" || $0.room == model.selectedRoom)
            }), showRoom: model.selectedRoom == "All rooms")
        }
    }

    private func label(_ title: String, symbol: String, count: Int?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).frame(width: 17)
            Text(title).font(.roomName)
            if let count { Text("\(count)").font(.caption) }
            Spacer()
        }.foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 2)
    }
    private func rows(_ devices: [HomeDevice], showRoom: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(devices) { device in HomeDeviceRow(model: model, device: device, showRoom: showRoom) }
            if devices.isEmpty { empty }
        }
    }
    private var empty: some View { Text("No matching devices").font(.callout).foregroundStyle(.secondary).padding(22) }
    private func roomSymbol(_ room: String) -> String {
        switch room { case "Bedroom", "Guest room": "bed.double"; case "Living room": "sofa"; case "Garage": "car"; default: "door.left.hand.open" }
    }
}

private struct ClimateSummary: View {
    @Bindable var model: HomeModel
    var body: some View {
        HStack(spacing: 10) {
            Button { model.climateExpanded.toggle() } label: {
                HStack(spacing: 10) {
                    Text(model.valueLabel(model.temperature)).font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hallway").font(.lightName)
                        HStack(spacing: 4) {
                            Image(systemName: model.heating ? "flame.fill" : "thermometer.medium")
                            Text(model.climateStatus)
                            Image(systemName: model.climateExpanded ? "chevron.up" : "chevron.down").font(.caption2)
                        }.font(.caption).foregroundStyle(model.heating ? Color.orange : .secondary)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Hallway, \(model.valueLabel(model.temperature)), \(model.climateStatus). \(model.climateExpanded ? "Hide" : "Show") climate settings")
            Spacer(minLength: 2)
            VStack(spacing: 5) {
                Text("HEAT TO").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Button { model.stepTarget(-1) } label: { Image(systemName: "minus").frame(width: 20, height: 22) }
                        .accessibilityLabel("Decrease target temperature")
                    Text(model.targetLabel).font(.headline).monospacedDigit().frame(minWidth: 27)
                        .accessibilityLabel("Target \(model.targetLabel)")
                    Button { model.stepTarget(1) } label: { Image(systemName: "plus").frame(width: 20, height: 22) }
                        .accessibilityLabel("Increase target temperature")
                }.buttonStyle(.borderless).disabled(!model.heatEnabled || model.eco)
            }
        }.padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 17)
    }
}

private struct ClimateDetails: View {
    @Bindable var model: HomeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Humidity", systemImage: "humidity").foregroundStyle(.secondary)
                Spacer(); Text("\(model.humidity)%").monospacedDigit()
            }.font(.callout)
            Picker("Mode", selection: $model.heatEnabled) { Text("Off").tag(false); Text("Heat").tag(true) }
                .pickerStyle(.segmented)
            Toggle("Eco temperature", isOn: $model.eco).toggleStyle(.switch).controlSize(.small).disabled(!model.heatEnabled)
            if model.eco { Text("Heat only below \(model.valueLabel(50)).").font(.caption).foregroundStyle(.secondary) }
            Picker("Units", selection: $model.celsius) { Text("°F").tag(false); Text("°C").tag(true) }
                .pickerStyle(.segmented)
            Text("Temperature changes are simulated in this preview.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.top, 10)
    }
}

private struct HomeDeviceRow: View {
    @Bindable var model: HomeModel
    let device: HomeDevice
    let showRoom: Bool
    var expanded: Bool { model.expandedDevices.contains(device.id) }
    var rgb: ColorScience.RGB {
        if device.colorMode {
            let c = NSColor(hue: device.hue / 360, saturation: 0.75, brightness: 1, alpha: 1)
            return .init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        }
        return ColorScience.rgb(fromMireds: Int(1_000_000 / device.warmth))
    }
    var status: String {
        if !device.reachable { return "Unavailable" }
        let power = device.isOn ? device.brightness.map { "\(Int($0))%" } ?? "On" : "Off"
        return showRoom ? "\(device.room) · \(power)" : power
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                DeviceSwatch(color: rgb, isOn: device.isOn, ready: device.reachable, isPlug: device.category == .devices)
                Button {
                    if expanded { model.expandedDevices.remove(device.id) } else { model.expandedDevices.insert(device.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.lightName).foregroundStyle(.primary).lineLimit(1)
                        Text(status).font(.lightStatus).foregroundStyle(device.reachable ? Color.secondary : .orange).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(device.name), \(status). \(expanded ? "Hide" : "Show") controls")
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Toggle("", isOn: Binding(get: { device.isOn }, set: { model.power(device.id, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(!device.reachable)
                    .accessibilityLabel("\(device.name) power")
            }
            if expanded { controls }
        }.deviceRowSurface(expanded: expanded, animatesExpansion: false)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let brightness = device.brightness {
                GradientSlider(value: Binding(get: { brightness }, set: { model.setBrightness(device.id, $0) }),
                               range: 1...100, gradient: .brightness(of: rgb), label: "\(device.name) brightness",
                               format: { "\(Int($0)) percent" }, isEnabled: device.reachable && device.isOn)
                if device.supportsTemperature { HStack {
                    Text("Warmth").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Text("\(Int(device.warmth)) K").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                GradientSlider(value: Binding(get: { device.warmth }, set: { v in model.change(device.id) { $0.warmth = v; $0.colorMode = false } }),
                               range: 2200...6500, gradient: .colorTemperature, label: "\(device.name) warmth",
                               format: { "\(Int($0)) Kelvin" }, isEnabled: device.reachable && device.isOn)
                }
                if device.supportsColor {
                    Toggle("Color", isOn: Binding(get: { device.colorMode }, set: { v in model.change(device.id) { $0.colorMode = v } }))
                        .toggleStyle(.switch).controlSize(.mini)
                    if device.colorMode {
                        GradientSlider(value: Binding(get: { device.hue }, set: { v in model.change(device.id) { $0.hue = v } }),
                                       range: 0...360, gradient: .hue, label: "\(device.name) color",
                                       format: { "\(Int($0)) degrees" }, isEnabled: device.reachable && device.isOn)
                    }
                }
            } else { Text("On/off control").font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Text("Room").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Room", selection: Binding(get: { device.room }, set: { v in model.change(device.id) { $0.room = v } })) {
                    ForEach(model.rooms, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().controlSize(.small).fixedSize()
            }
            if device.isPlug {
                Picker("Use as", selection: Binding(get: { device.category }, set: { v in model.change(device.id) { $0.category = v } })) {
                    Text("Light").tag(HomeCategory.lights); Text("Device").tag(HomeCategory.devices)
                }.pickerStyle(.segmented).labelsHidden()
            }
            HStack {
                Text(device.source.rawValue).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { model.change(device.id) { $0.favorite.toggle() } } label: {
                    Label(device.favorite ? "Favorite" : "Add favorite", systemImage: device.favorite ? "star.fill" : "star")
                        .font(.caption)
                }.buttonStyle(.borderless)
            }
        }
    }
}
