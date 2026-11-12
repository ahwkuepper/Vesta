import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Portable preferences only. No provider credentials or device state is included.
struct HomeLayoutFile: Codable, Equatable {
    var format = "vesta-home-layout"
    var version = 1
    var rooms: [String]
    var placements: [String: DevicePlacement]
    var celsius: Bool
    var roomPriorities: [String: RoomPriority]? = nil
    var smartOrder: Bool? = nil
    static let byteLimit = 262_144

    func validated() throws -> Self {
        func label(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 160
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard format == "vesta-home-layout", version == 1, rooms.count <= 100,
              (roomPriorities?.count ?? 0) <= 100, roomPriorities?.keys.allSatisfy(label) ?? true,
              placements.count <= 1024, rooms.allSatisfy(label), placements.allSatisfy({ id, placement in
                  (id.hasPrefix("hue:") || id.hasPrefix("kasa:")) && id.count <= 400
                    && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
                    && (placement.room.map(label) ?? true)
              }) else { throw LayoutFileError.invalid }
        return self
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= byteLimit else { throw LayoutFileError.tooLarge }
        do { return try JSONDecoder().decode(Self.self, from: data).validated() }
        catch { throw LayoutFileError.invalid }
    }
    func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.byteLimit else { throw LayoutFileError.tooLarge }
        return data
    }
}

enum LayoutFileError: LocalizedError {
    case invalid, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: "That isn’t a supported Vesta Home layout file. Your current settings were kept."
        case .tooLarge: "The layout file exceeds the 256 KB limit. Your current settings were kept."
        }
    }
}

struct HomeLayoutDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw LayoutFileError.invalid }
        _ = try HomeLayoutFile.decode(data); self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
