import Foundation
import Darwin
import OSLog
import NestCore

@main struct Command {
    static let help = """
    Nest reader — read-only Google Nest thermostat access

      nest-reader setup --credentials PATH --project DEVICE_ACCESS_PROJECT_UUID
      nest-reader authorize                         Print the consent link
      nest-reader connect --authorization PATH      Save refresh token to Keychain
      nest-reader read [--json]                      Fetch current readings
      nest-reader status                            Check local configuration
      nest-reader forget                            Remove this reader's Keychain entry

    Credentials and refresh tokens stay in macOS Keychain. Authorization codes are
    read from files, never command-line arguments. Google OAuth Testing grants last
    seven days; use In production for long-term personal access. This tool does not
    change thermostat settings. The Google scope itself also permits control.
    """

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args == ["--help"] || args == ["help"] { print(help); return }
        // Serialize separate CLI processes, including authorize/connect. Otherwise
        // one process could overwrite another process's rotated token or state.
        let path = NSTemporaryDirectory() + "io.github.ahwkuepper.NestReader.\(getuid()).lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        var attributes = stat()
        guard descriptor >= 0, fstat(descriptor, &attributes) == 0,
              attributes.st_uid == getuid(), attributes.st_mode & S_IFMT == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            fail("Another Nest reader operation is running, or the operation lock is unavailable.")
        }
        defer { close(descriptor) }
        let reader = NestCore.NestReader()
        do {
            switch args.first {
            case "setup" where args.count == 5 && args[1] == "--credentials" && args[3] == "--project":
                let c = try Credentials.imported(readInputFile(args[2]), projectID: args[4])
                try await reader.setup(c)
                print("Client configuration saved in Keychain. Run authorize next.")
            case "authorize" where args.count == 1:
                print(try await reader.authorizationURL().absoluteString)
            case "connect" where args.count == 3 && args[1] == "--authorization":
                let data = try readInputFile(args[2])
                guard let redirect = String(data: data, encoding: .utf8) else { throw ReaderError.invalidFile }
                let readings = try await reader.connect(redirect: redirect)
                print("Refresh token saved in Keychain. Future reads refresh automatically.")
                print(readings.text)
            case "read" where args.count == 1 || args == ["read", "--json"]:
                let readings = try await reader.read()
                if args.contains("--json") {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(readings)
                    FileHandle.standardOutput.write(data)
                    print("")
                } else { print(readings.text) }
            case "status" where args.count == 1:
                print(try await reader.status())
            case "forget" where args.count == 1:
                try await reader.forget()
                print("Removed this reader's Keychain entry. To revoke Google's grant too, unlink the project in Nest Partner Connections.")
            default: fail(help)
            }
        } catch let error as ReaderError { fail(error.localizedDescription) }
        catch { fail("The operation failed. No credentials or response bodies were logged.") }
    }

    static func fail(_ message: String) -> Never {
        Logger(subsystem: "io.github.ahwkuepper.NestReader", category: "reader")
            .error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
