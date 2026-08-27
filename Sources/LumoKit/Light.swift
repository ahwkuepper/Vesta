import Foundation

/// A controllable bulb. `id` is the CoreBluetooth peripheral identifier, which is
/// stable per-Mac, so it is safe to persist in scenes and reconnect against later.
public struct Light: Identifiable, Sendable, Equatable {
    public typealias ID = UUID

    public let id: ID
    public var name: String
    public var model: String
    public var state: LightState
    public var connection: ConnectionState
    /// Signal strength, for surfacing "this bulb is far away" before it drops out.
    public var rssi: Int?
    public var capabilities: LightCapabilities

    public init(id: ID, name: String, model: String = "",
                state: LightState = .default,
                connection: ConnectionState = .discovered,
                rssi: Int? = nil,
                capabilities: LightCapabilities = .init()) {
        self.id = id
        self.name = name
        self.model = model
        self.state = state
        self.connection = connection
        self.rssi = rssi
        self.capabilities = capabilities
    }
}

/// What a particular fixture can actually do. Controls are shown only where they
/// mean something — a gradient strip on a plain bulb would be a lie.
public struct LightCapabilities: Sendable, Equatable {
    /// Number of colour points a gradient fixture accepts (Play lamps: 5), or nil.
    public var gradientPoints: Int?
    /// Built-in effect names the bridge reports, minus the "off" sentinel.
    public var effects: [String]

    public var supportsGradient: Bool { (gradientPoints ?? 0) > 0 }

    public init(gradientPoints: Int? = nil, effects: [String] = []) {
        self.gradientPoints = gradientPoints
        self.effects = effects
    }
}

/// Deliberately distinguishes "off" from "cannot be reached" from "cannot be
/// commanded". Collapsing these makes the app lie about what it knows.
public enum ConnectionState: Sendable, Equatable {
    /// Seen in an advertisement, not yet connected.
    case discovered
    case connecting
    /// Connected and commandable.
    case ready
    /// Connected, but the bulb refuses commands until a BLE bond exists.
    case needsPairing
    /// Was known, now out of range or not responding.
    case unreachable

    public var isCommandable: Bool { self == .ready }

    public var shortLabel: String {
        switch self {
        case .discovered:   "Found"
        case .connecting:   "Connecting…"
        case .ready:        "Ready"
        case .needsPairing: "Not paired"
        case .unreachable:  "Unreachable"
        }
    }
}

/// Everything a scene needs to restore, including off-ness — a scene that cannot
/// turn a light off is not a scene.
public struct LightState: Sendable, Equatable, Codable, Hashable {
    public var isOn: Bool
    /// 0…1. Mapped to the bulb's 1…254 at the protocol edge, not here.
    public var brightness: Double
    public var color: LightColor
    /// The dynamic effect the bulb is running, or nil for none. Read from the
    /// bridge rather than remembered locally, so an effect started from the Hue app
    /// or a wall switch shows here too.
    public var effect: String?

    public init(isOn: Bool, brightness: Double, color: LightColor,
                effect: String? = nil) {
        self.isOn = isOn
        self.brightness = brightness.clamped(to: 0...1)
        self.color = color
        self.effect = effect
    }

    public static let `default` = LightState(
        isOn: false, brightness: 0.6, color: .temperature(mireds: 366) // ~2700K
    )
}

/// A partial state update.
///
/// The bridge pushes events carrying only the fields that changed — a scene recall
/// sends colour without `on` or `dimming`. Rebuilding a whole `LightState` from one
/// defaults the absent fields, reporting lights as off at 50%, so updates must be
/// merged, never substituted.
public struct LightStateDelta: Sendable, Equatable {
    public var isOn: Bool?
    public var brightness: Double?
    public var color: LightColor?
    /// Double-optional on purpose: `nil` means the event said nothing about the
    /// effect, `.some(nil)` means it reported the effect was cleared.
    public var effect: String??

    public init(isOn: Bool? = nil, brightness: Double? = nil, color: LightColor? = nil,
                effect: String?? = nil) {
        self.isOn = isOn
        self.brightness = brightness
        self.color = color
        self.effect = effect
    }

    /// A delta that sets everything, for transports that report complete state.
    public init(_ state: LightState) {
        self.init(isOn: state.isOn, brightness: state.brightness, color: state.color,
                  effect: .some(state.effect))
    }

    public var isEmpty: Bool {
        isOn == nil && brightness == nil && color == nil && effect == nil
    }

    public func applied(to state: LightState) -> LightState {
        LightState(isOn: isOn ?? state.isOn,
                   brightness: brightness ?? state.brightness,
                   color: color ?? state.color,
                   effect: effect ?? state.effect)
    }
}

/// A gradient across a fixture's pixels, as a small ordered palette. The bridge
/// interpolates between the points; it does not take one colour per pixel.
public struct LightGradient: Sendable, Equatable, Hashable {
    public var points: [LightColor]
    /// `interpolated_palette`, `interpolated_palette_mirrored`, `random_pixelated`,
    /// `segmented_palette`.
    public var mode: String

    public init(points: [LightColor], mode: String = "interpolated_palette") {
        self.points = points
        self.mode = mode
    }

    /// Every point the same colour, which makes a gradient fixture behave like an
    /// ordinary lamp — the usual thing to want from a Play lamp lighting a room.
    public static func uniform(_ color: LightColor, points: Int = 5) -> LightGradient {
        LightGradient(points: Array(repeating: color, count: max(2, points)))
    }
}

public enum LightColor: Sendable, Equatable, Codable, Hashable {
    /// Mireds (reciprocal megakelvin). LCB002 covers 153 (6500K) … 500 (2000K).
    case temperature(mireds: Int)
    /// CIE 1931 xy chromaticity.
    case xy(x: Double, y: Double)

    public static let miredRange = 153...500

    public var isTemperature: Bool {
        if case .temperature = self { return true }
        return false
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}
