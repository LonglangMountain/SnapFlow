import Foundation
import SwiftData

/// Persisted metadata for a captured screenshot (design §19).
@Model
final class ScreenshotRecord {
    var id: UUID
    var filePath: String
    var createdAt: Date
    var width: Int
    var height: Int
    var type: String

    init(id: UUID = UUID(),
         filePath: String,
         createdAt: Date = Date(),
         width: Int,
         height: Int,
         type: String) {
        self.id = id
        self.filePath = filePath
        self.createdAt = createdAt
        self.width = width
        self.height = height
        self.type = type
    }
}

/// SwiftData-backed store for screenshot history. Runs on the main actor since
/// the model context is used from UI code.
@MainActor
final class HistoryStore {

    static let shared = HistoryStore()

    private let container: ModelContainer?

    private init() {
        do {
            container = try ModelContainer(for: ScreenshotRecord.self)
        } catch {
            NSLog("SnapFlow: SwiftData unavailable: \(error.localizedDescription)")
            container = nil
        }
    }

    /// Keep at most this many history records; older ones are pruned.
    private let maxRecords = 100

    func record(filePath: String, width: Int, height: Int, type: String) {
        guard let context = container?.mainContext else { return }
        context.insert(ScreenshotRecord(filePath: filePath,
                                        width: width,
                                        height: height,
                                        type: type))
        try? context.save()
        prune()
    }

    /// Trim the list to `maxRecords`, dropping the oldest records (files kept).
    private func prune() {
        guard let context = container?.mainContext else { return }
        let records = all()   // newest first
        guard records.count > maxRecords else { return }
        for record in records[maxRecords...] { context.delete(record) }
        try? context.save()
    }

    /// All records, most recent first.
    func all() -> [ScreenshotRecord] {
        guard let context = container?.mainContext else { return [] }
        let descriptor = FetchDescriptor<ScreenshotRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func mostRecent() -> ScreenshotRecord? {
        all().first
    }

    /// Remove the record(s) with the given file path (does not touch the file).
    func delete(path: String) {
        guard let context = container?.mainContext else { return }
        for record in all() where record.filePath == path {
            context.delete(record)
        }
        try? context.save()
    }

    /// Clear the whole history list (files on disk are kept).
    func clearRecords() {
        guard let context = container?.mainContext else { return }
        for record in all() { context.delete(record) }
        try? context.save()
    }
}
