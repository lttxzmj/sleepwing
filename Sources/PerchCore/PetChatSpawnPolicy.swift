import Foundation

/// Perch's own pet-chat subprocesses would otherwise trip the very
/// provider hooks Perch installs, so every reply reported itself back as
/// a finished user task (and the pet celebrated its own answer). Chat
/// spawns mark themselves with this environment variable and the relay
/// drops marked events; dispatch runs stay unmarked and report normally.
public enum PetChatSpawnPolicy {
    public static let environmentKey = "PERCH_CHAT"
    public static let environmentValue = "1"

    /// POSIX-shell guard emitted near the top of the relay script.
    public static var relayGuard: String {
        "if [ \"${\(environmentKey)}\" = \"\(environmentValue)\" ]; then exit 0; fi"
    }
}
