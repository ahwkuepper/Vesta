import Foundation
import HomePreviewUI

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(i + 1) {
    do { try HomeSnapshot.render(to: URL(fileURLWithPath: arguments[i + 1])) }
    catch { FileHandle.standardError.write(Data("Could not render Home previews.\n".utf8)); exit(1) }
} else { HomePreviewApp.run() }
