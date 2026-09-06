import Foundation

public enum IntegrationHealthPolicy {
    /// Providers whose hooks vanished after having delivered real
    /// lifecycle events — the "installed but silently dead" moment this
    /// product category gets blamed for most. Requiring prior proof of
    /// life keeps a fresh install from warning about tools the user
    /// never connected, and an in-app uninstall clears the proof, so
    /// only external removal (another tool, an update, a reset) warns.
    public static func lostHooks(
        everConnected: Set<AgentProvider>,
        installed: Set<AgentProvider>
    ) -> Set<AgentProvider> {
        everConnected.subtracting(installed)
    }
}
