import SwiftUI
import KasaKit

/// Reuses the tested device lifecycle, coalescing and schedules in the combined app.
@MainActor public final class KasaHome {
    private let model: KasaModel
    public init(demo: Bool = false) { model = KasaModel(demo: demo) }
    public var devices: [KasaDevice] { model.devices.map { original in
        var device = original
        if let draft = model.controlDraft[device.id] {
            switch draft {
            case .power(let on): device.isOn = on
            case .brightness(let value): device.brightness = value
            case .temperature(let value): device.colorTemperature = value
            case .color(let hue, let saturation): device.hue = hue; device.saturation = saturation; device.colorTemperature = 0
            }
        }
        return device
    } }
    public var busy: Set<String> { model.busy }
    public var error: String? { model.error }
    public var refreshing: Bool { model.isRefreshing }
    public var signedIn: Bool { model.signedIn }
    public func start() async { await model.start() }
    public func refresh() async { await model.reloadCredentials(); await model.refresh(discover: true) }
    public func dismissError() { model.error = nil }
    public func power(_ on: Bool, device: KasaDevice) { model.command(.power(on), device: device) }
    public func control(_ command: KasaCommand, device: KasaDevice) { model.setControl(command, for: device) }
    public func scheduleView(for device: KasaDevice) -> some View {
        KasaScheduleView(device: device, model: model).task { await self.model.loadSchedules(for: device) }
    }
    public func accountView(close: @escaping () -> Void) -> some View {
        VStack {
            KasaAccountView(model: model, close: close)
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange).padding() }
        }
    }
}
