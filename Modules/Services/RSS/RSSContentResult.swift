import Foundation

struct RSSContentResult: Sendable {
    enum Stop: Sendable { case complete, loop, duplicate, budget, failed }
    var html: String
    var variables: [String: String]
    var pageCount: Int
    var stop: Stop
    var isPartial: Bool { stop != .complete }
}
