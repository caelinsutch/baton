import AppKit
import BatonCore

/// Opens the links on a task.
///
/// Nothing opens on its own. The human clicks, and the scheme allow list applies
/// again here, because a task may predate a change to that list.
enum LinkOpener {
    static func open(_ link: BatonTask.Link, task: BatonTask?) {
        guard Guardrails.isAllowed(urlString: link.url), let url = URL(string: link.url) else {
            NSSound.beep()
            return
        }

        switch link.openIn {
        case .browser:
            NSWorkspace.shared.open(url)
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .editor:
            openInEditor(url)
        case .terminal:
            openInTerminal(url)
        }
    }

    /// Opens the worktree of a task in the preferred editor.
    static func openWorktree(_ task: BatonTask) {
        guard let path = task.repo?.worktreePath else { return }
        openInEditor(URL(fileURLWithPath: path))
    }

    static func symbol(for link: BatonTask.Link) -> String {
        switch link.openIn {
        case .browser: return "safari"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        case .finder: return "folder"
        }
    }

    // MARK: - Targets

    /// Tries the editor schemes in order, then falls back to Finder. A missing
    /// editor must not look like a broken button.
    private static func openInEditor(_ url: URL) {
        if url.scheme != "file" {
            NSWorkspace.shared.open(url)
            return
        }
        let path = url.path
        let candidates = ["cursor", "vscode", "zed", "windsurf"]
        for scheme in candidates {
            guard let candidate = URL(string: "\(scheme)://file\(path)") else { continue }
            if NSWorkspace.shared.urlForApplication(toOpen: candidate) != nil {
                NSWorkspace.shared.open(candidate)
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func openInTerminal(_ url: URL) {
        let path = url.scheme == "file" ? url.path : url.absoluteString
        // AppleScript would need automation permission. `open -a` does not.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", terminalName(), path]
        try? process.run()
    }

    private static func terminalName() -> String {
        let preferred = ["Ghostty", "iTerm", "Warp", "Alacritty", "kitty"]
        for name in preferred
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId(for: name)) != nil {
            return name
        }
        return "Terminal"
    }

    private static func bundleId(for name: String) -> String {
        switch name {
        case "Ghostty": return "com.mitchellh.ghostty"
        case "iTerm": return "com.googlecode.iterm2"
        case "Warp": return "dev.warp.Warp-Stable"
        case "Alacritty": return "org.alacritty"
        case "kitty": return "net.kovidgoyal.kitty"
        default: return "com.apple.Terminal"
        }
    }
}
