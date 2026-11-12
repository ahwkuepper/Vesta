import SwiftUI
import NestCore

struct ClimateSummary: View {
    @Bindable var model: HomeModel
    var body: some View {
        HStack(spacing: 10) {
            Button { model.climateExpanded.toggle() } label: {
                HStack(spacing: 10) {
                    Text(model.temperatureLabel(model.thermostat?.temperatureCelsius))
                        .font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.thermostat?.name ?? "Thermostat").font(.headline).lineLimit(1)
                        HStack(spacing: 4) {
                            Image(systemName: model.thermostat?.hvac == "HEATING" ? "flame.fill" : "thermometer.medium")
                            Text(status).lineLimit(1)
                            Image(systemName: model.climateExpanded ? "chevron.up" : "chevron.down").font(.caption2)
                        }.font(.caption).foregroundStyle(model.nestError == nil ? Color.secondary : .orange)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(model.thermostat?.name ?? "Thermostat"), \(model.temperatureLabel(model.thermostat?.temperatureCelsius)). \(status). Climate settings")
            Spacer(minLength: 0)
            if let t = model.thermostat {
                if t.eco == "MANUAL_ECO" { Label("Eco", systemImage: "leaf").font(.callout).foregroundStyle(.green) }
                else if t.mode == "HEAT" || t.mode == "COOL" { TargetControl(model: model, cooling: t.mode == "COOL") }
                else { Text(t.mode == "HEATCOOL" ? "Auto" : t.mode == "OFF" ? "Off" : "—").font(.callout).foregroundStyle(.secondary) }
            } else if model.nestBusy { ProgressView().controlSize(.small) }
        }.padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 17)
    }
    private var status: String {
        if model.nestCommandBusy { return "Updating…" }
        if model.targetDraft != nil { return "Choosing temperature…" }
        if model.nestError != nil { return model.thermostat == nil ? "Connect Nest" : "Last reading" }
        guard let t = model.thermostat else { return model.nestBusy ? "Connecting…" : "Not connected" }
        if t.connectivity != "ONLINE" { return "Offline · last reading" }
        if t.mode == "OFF" { return "Off" }
        if t.eco == "MANUAL_ECO" { return "Eco" }
        return t.hvac == "OFF" ? "Idle" : t.hvac?.capitalized ?? "Unknown"
    }
}

private struct TargetControl: View {
    @Bindable var model: HomeModel
    var cooling: Bool
    var body: some View {
        VStack(spacing: 5) {
            Text(cooling ? "COOL TO" : "HEAT TO").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Button { model.stepTarget(-1, cooling: cooling) } label: { Image(systemName: "minus").frame(width: 20, height: 22) }
                    .accessibilityLabel("Decrease \(cooling ? "cooling" : "heating") target")
                Text(model.temperatureLabel(model.targetTemperature(cooling: cooling)))
                    .font(.headline).monospacedDigit().frame(minWidth: 27)
                Button { model.stepTarget(1, cooling: cooling) } label: { Image(systemName: "plus").frame(width: 20, height: 22) }
                    .accessibilityLabel("Increase \(cooling ? "cooling" : "heating") target")
            }.buttonStyle(.borderless).disabled(!model.climateWritable || model.thermostat?.eco != "OFF")
        }
    }
}

struct ClimateDetails: View {
    @Bindable var model: HomeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.nestError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if model.nestRetryAt == nil { Button("Nest connection…") { model.settings = true } }
            }
            if let t = model.thermostat {
                if let readings = model.nestReadings, readings.thermostats.count > 1 {
                    Picker("Thermostat", selection: $model.thermostatIndex) {
                        ForEach(readings.thermostats.indices, id: \.self) { Text(readings.thermostats[$0].name).tag($0) }
                    }.disabled(model.nestCommandBusy)
                }
                HStack { Label("Humidity", systemImage: "humidity").foregroundStyle(.secondary); Spacer(); Text(t.humidityPercent.map { String(format: "%.0f%%", $0) } ?? "—") }
                    .font(.callout)
                if !t.availableModes.isEmpty {
                    Picker("Mode", selection: Binding(get: { t.mode ?? "" }, set: { model.nestCommand(.mode($0)) })) {
                        ForEach(t.availableModes, id: \.self) { Text($0 == "HEATCOOL" ? "Auto" : $0.capitalized).tag($0) }
                    }.controlSize(.small).disabled(!model.climateWritable)
                }
                if t.eco != nil {
                    Toggle("Eco temperature", isOn: Binding(get: { t.eco == "MANUAL_ECO" }, set: { model.nestCommand(.eco($0)) }))
                        .toggleStyle(.switch).controlSize(.small).disabled(!model.climateWritable || t.mode == "OFF")
                }
                if t.eco == "MANUAL_ECO" {
                    if let heat = t.ecoHeatCelsius { Text("Eco heats below \(model.temperatureLabel(heat)).").font(.caption).foregroundStyle(.secondary) }
                    if let cool = t.ecoCoolCelsius { Text("Eco cools above \(model.temperatureLabel(cool)).").font(.caption).foregroundStyle(.secondary) }
                } else if t.mode == "HEATCOOL" {
                    HStack { TargetControl(model: model, cooling: false); Spacer(); TargetControl(model: model, cooling: true) }
                }
                Picker("Units", selection: $model.celsius) { Text("°F").tag(false); Text("°C").tag(true) }.pickerStyle(.segmented)
            }
            HStack {
                if let fetched = model.nestReadings?.fetchedAt {
                    Text("From Google \(fetched.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refreshNest(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.nestBusy || model.nestCommandBusy || model.targetDraft != nil || model.nestRetryAt != nil).accessibilityLabel("Refresh thermostat")
            }
            Text("Temperature changes send after you pause briefly. Updates can take a moment.").font(.caption2).foregroundStyle(.secondary)
        }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.top, 10)
    }
}
