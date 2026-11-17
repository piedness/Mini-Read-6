import Foundation
import SwiftData

@Model
final class ReadingSession {
    /// Stable key to group sessions by book.
    var bookKey: String
    var bookTitle: String
    var startedAt: Date
    var endedAt: Date
    /// Stored in seconds for precise aggregation.
    var durationSeconds: Int

    init(
        bookKey: String,
        bookTitle: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Int
    ) {
        self.bookKey = bookKey
        self.bookTitle = bookTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
    }
}
