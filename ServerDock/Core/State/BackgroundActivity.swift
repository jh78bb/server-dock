import Foundation

/// Shared background activity descriptor decoupling the bottom-left center from individual features.
/// Grouping hostId/name are value snapshots captured by @MainActor AppModel at creation, allowing this type
/// to satisfy nonisolated Identifiable. payload holds live tasks observed by main-thread rows.
/// Add new features through a payload case/row without changing center layout/grouping.
struct BackgroundActivity: Identifiable {
    enum Payload {
        case forward(rule: ForwardRule, manager: ForwardManager)
        case transfer(UploadTask)   // Upload/download direction is distinguished by UploadTask.direction.
        case extract(ExtractTask)
    }

    let id: String
    let hostId: String?          // Grouping key for grouping tasks by host.
    let fallbackHostName: String // Fallback display name if the host was deleted; views prefer the current host name when available.
    let isFinished: Bool         // Whether the task has ended (completed/canceled/failed); AppModel reads phase and updates this on the main thread.
    let payload: Payload
}
