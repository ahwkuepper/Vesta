import SwiftUI
import LumoKit

/// One room: a header that controls the whole room, its scenes, and its lights.
///
/// Rooms come from the bridge, so this matches how the lights are grouped in the
/// Hue app and on any wall switch — Lumo does not invent a second organisation
/// scheme for the user to keep in sync.
struct RoomSection: View {
    let room: Room
    @Bindable var store: LightStore
    @Binding var expansion: Expansion
    @Binding var namingRoomID: Room.ID?

    @State private var newSceneName = ""
    @FocusState private var nameFocused: Bool

    private var lights: [Light] { store.lights(in: room) }
    private var scenes: [RoomScene] { store.scenes(in: room) }
    private var isNaming: Bool { namingRoomID == room.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isNaming { nameField } else if !scenes.isEmpty { sceneStrip }
            ForEach(lights) { light in
                LightRow(light: light, store: store, expansion: $expansion, roomID: room.id)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: room.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(room.name)
                .lineLimit(1)
                .font(.system(size: 12, weight: .semibold))

            Text("\(lights.filter(\.state.isOn).count)/\(lights.count)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            Spacer()

            Button {
                newSceneName = ""
                namingRoomID = isNaming ? nil : room.id
                nameFocused = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isNaming ? Color.accentColor : .secondary)
            .help("Save these lights as a scene in \(room.name)")

            // Whole-room switch: the bridge applies it in one call, so the room
            // switches together instead of rippling bulb by bulb.
            Toggle("", isOn: Binding(
                get: { store.isRoomOn(room) },
                set: { store.setRoomPower($0, room: room) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            // Matches the header switch. A room whose lights are all unreachable
            // cannot be switched, and the control should say so rather than
            // accepting a press that does nothing.
            .disabled(!lights.contains { $0.connection.isCommandable })
            .accessibilityLabel("\(room.name) lights")
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Scenes

    private var sceneStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(scenes) { scene in
                    SceneChip(scene: scene) {
                        store.recall(scene)
                    } onDelete: {
                        store.deleteScene(scene)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 1)
            .chipGroup()
        }
        .scrollIndicators(.never)
    }

    private var nameField: some View {
        HStack(spacing: 6) {
            TextField("Scene name", text: $newSceneName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($nameFocused)
                .onSubmit(save)

            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(trimmedName.isEmpty)

            Button("Cancel") { namingRoomID = nil }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
    }

    private var trimmedName: String {
        newSceneName.trimmingCharacters(in: .whitespaces)
    }

    private func save() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        namingRoomID = nil
        Task { await store.saveScene(named: name, in: room) }
    }
}

/// A scene as a tappable chip.
///
/// Scenes created in the Hue app are recallable but not deletable here — they may be
/// wired to routines or a wall switch, and deleting one from a menu bar popover is
/// not a decision to make on the user's behalf.
struct SceneChip: View {
    let scene: RoomScene
    let onApply: () -> Void
    let onDelete: () -> Void

    /// The colour this scene actually produces, or none.
    ///
    /// Untinted when the bridge reports no usable colour: a scene that turns the
    /// room off has no colour, and inventing one is decoration posing as
    /// information.
    private var tint: Color? {
        scene.tint.map {
            Color(ColorScience.rgb(for: LightState(isOn: true, brightness: 1, color: $0)))
        }
    }

    var body: some View {
        Button(action: onApply) {
            HStack(spacing: 5) {
                Image(systemName: scene.isActive ? "checkmark" : "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                Text(scene.name).lineLimit(1)
            }
            .chipMetrics()
            // The bridge reports which scene the room actually matches, and drops it
            // the moment any light changes — so this says "these are your current
            // settings", not "this is what you last pressed".
            .chipStyle(isActive: scene.isActive)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(scene.name) scene")
        .accessibilityAddTraits(scene.isActive ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if scene.isEditable {
                Button("Delete Scene", role: .destructive, action: onDelete)
            } else {
                Text("Created in the Hue app")
            }
        }
        .help(scene.isEditable ? "Apply “\(scene.name)”"
                               : "Apply “\(scene.name)” (created in the Hue app)")
        .accessibilityLabel("Apply scene \(scene.name)")
    }
}
