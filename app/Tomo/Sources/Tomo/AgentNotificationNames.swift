import Foundation

extension Notification.Name {
    /// Broadcast when local agent CLI installation or configuration status changes
    /// (e.g. from Settings refresh, Gateway page refresh, or after configuring an agent).
    public static let agentIntegrationStatusDidChange = Notification.Name("codexling.agentIntegrationStatusDidChange")
}
