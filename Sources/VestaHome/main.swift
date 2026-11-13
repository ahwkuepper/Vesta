import HomeUI
import Foundation
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--snapshot" {
    try HomeSnapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[2]))
} else { VestaHomeApp.run() }
