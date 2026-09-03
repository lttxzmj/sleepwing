import Foundation

/// Resolves resources without SwiftPM's generated `Bundle.module` fallback,
/// which embeds the developer's absolute `.build` path. A distributed app
/// always uses its signed `Contents/Resources`; `swift run` uses the resource
/// bundle beside the executable.
enum PerchResources {
    static let bundle: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main
        }
        guard let executableDirectory = Bundle.main.executableURL?
            .deletingLastPathComponent() else {
            return Bundle.main
        }
        let developmentBundle = executableDirectory
            .appendingPathComponent("Perch_Perch.bundle", isDirectory: true)
        return Bundle(url: developmentBundle) ?? Bundle.main
    }()

    /// `swift run` has no app bundle, so SwiftUI's literal localization
    /// keys — always resolved against Bundle.main — would render as raw
    /// keys. Mirror the resource bundle's lproj folders beside the
    /// executable so the dev binary shows words; the packaged app
    /// (bundleURL ends in .app, lprojs copied into Contents/Resources)
    /// never enters this path.
    static func linkDevelopmentLocalizations() {
        guard Bundle.main.bundleURL.pathExtension != "app",
              let executableDirectory = Bundle.main.executableURL?
                  .deletingLastPathComponent() else { return }
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: bundle.bundleURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.pathExtension == "lproj" {
            let target = executableDirectory
                .appendingPathComponent(entry.lastPathComponent)
            if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil {
                try? fileManager.removeItem(at: target)
            } else if fileManager.fileExists(atPath: target.path) {
                continue
            }
            try? fileManager.createSymbolicLink(
                at: target,
                withDestinationURL: entry
            )
        }
    }
}
