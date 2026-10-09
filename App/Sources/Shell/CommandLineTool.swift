import AppKit

/// Installs the `treemap` shell shim (bundled in Contents/Resources) as a symlink.
/// No privilege escalation: /usr/local/bin when the user can write there, else ~/.local/bin.
@MainActor
enum CommandLineTool {
    private struct InstallError: LocalizedError {
        let errorDescription: String?
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

    private static func performInstall() throws -> (link: String, directoryOnPath: Bool) {
        guard let script = Bundle.main.url(forResource: "treemap", withExtension: nil) else { throw InstallError(errorDescription: "The command line tool is missing from the app bundle.") }
        let fm = FileManager.default
        let system = "/usr/local/bin"
        var isDir: ObjCBool = false
        let systemUsable = fm.fileExists(atPath: system, isDirectory: &isDir) && isDir.boolValue && fm.isWritableFile(atPath: system)
        let dir = systemUsable ? system : NSHomeDirectory() + "/.local/bin"
        let link = dir + "/treemap"
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil || fm.fileExists(atPath: link) {
                // Only replace a previous Treemap install (possibly from a moved app).
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: link), dest.hasSuffix("/Contents/Resources/treemap") else {
                    throw InstallError(errorDescription: "\(link) already exists and is not Treemap's. Remove it or rename it, then try again.")
                }
                try fm.removeItem(atPath: link)
            }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: script.path)
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            return (link, dir == system || path.split(separator: ":").contains { String($0) == dir })
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError(errorDescription: "\(error.localizedDescription)\n\nTarget: \(link)")
        }
    }
}
