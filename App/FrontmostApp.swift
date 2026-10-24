import AppKit
import VoiceInputCore

struct FrontmostApp: FrontmostAppProvider {
    func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
