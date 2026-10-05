import AppKit

/// Installs the `treemap` shell shim (bundled in Contents/Resources) as a symlink.
/// No privilege escalation: /usr/local/bin when the user can write there, else ~/.local/bin.
@MainActor
enum CommandLineTool {
    struct Result {
        var link: String
        var directoryOnPath: Bool
    }

    enum Failure: LocalizedError {
        case missingScript
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .missingScript: "The command line tool is missing from the app bundle."
            case .failed(let m): m
            }
        }
    }

    static func install() {
        let alert = NSAlert()
        do {
            let r = try performInstall()
            alert.messageText = "Command line tool installed"
            var info = "\(r.link) now opens folders in Treemap:\n\n    treemap ~/Downloads"
            if !r.directoryOnPath {
                let dir = (r.link as NSString).deletingLastPathComponent
                info += "\n\n\(dir) is not on your PATH. Add this line to ~/.zshrc:\n\n    export PATH=\"\(dir):$PATH\""
            }
            alert.informativeText = info
            alert.alertStyle = .informational
        } catch {
            alert.messageText = "Could not install the command line tool"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func performInstall() throws -> Result {
        guard let script = Bundle.main.url(forResource: "treemap", withExtension: nil) else { throw Failure.missingScript }
        let fm = FileManager.default
        let system = "/usr/local/bin"
        var isDir: ObjCBool = false
        let systemUsable = fm.fileExists(atPath: system, isDirectory: &isDir) && isDir.boolValue && fm.isWritableFile(atPath: system)
        let dir = systemUsable ? system : NSHomeDirectory() + "/.local/bin"
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let link = dir + "/treemap"
            if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil || fm.fileExists(atPath: link) {
                try fm.removeItem(atPath: link)
            }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: script.path)
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            return Result(link: link, directoryOnPath: dir == system || path.split(separator: ":").contains { String($0) == dir })
        } catch {
            throw Failure.failed("\(error.localizedDescription)\n\nTarget: \(dir)/treemap")
        }
    }
}
