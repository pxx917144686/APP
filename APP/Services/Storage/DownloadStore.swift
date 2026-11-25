import Foundation
import GRDB

struct DownloadTaskRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "download_task"

    var id: String
    var bundleIdentifier: String
    var version: String
    var name: String
    var packageIdentifier: Int
    var packageIconURL: String?
    var packagePrice: Double?
    var packageCurrency: String?
    var versionId: String?
    var status: String
    var progress: Double
    var error: String?
    var speed: String
    var localFilePath: String?
    var createdAt: Double
    var isCompleted: Bool
    var isActive: Bool
    var isWaiting: Bool
    var isTestFlight: Bool
    var queuePosition: Int?
}

final class DownloadStore {
    static let shared = DownloadStore()

    private var dbQueue: DatabaseQueue?

    private init() {
        open()
    }

    private var databaseURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads.sqlite")
    }

    private func open() {
        do {
            let db = try DatabaseQueue(path: databaseURL.path)
            try migrator.migrate(db)
            dbQueue = db
        } catch {
            dbQueue = nil
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "download_task") { table in
                table.column("id", .text).primaryKey()
                table.column("bundleIdentifier", .text).notNull()
                table.column("version", .text).notNull()
                table.column("name", .text).notNull()
                table.column("packageIdentifier", .integer).notNull()
                table.column("packageIconURL", .text)
                table.column("packagePrice", .double)
                table.column("packageCurrency", .text)
                table.column("versionId", .text)
                table.column("status", .text).notNull()
                table.column("progress", .double).notNull().defaults(to: 0)
                table.column("error", .text)
                table.column("speed", .text)
                table.column("localFilePath", .text)
                table.column("createdAt", .double).notNull()
                table.column("isCompleted", .boolean).notNull().defaults(to: false)
                table.column("isActive", .boolean).notNull().defaults(to: false)
                table.column("isWaiting", .boolean).notNull().defaults(to: false)
                table.column("queuePosition", .integer)
            }
            try db.create(
                index: "download_task_queue",
                on: "download_task",
                columns: ["queuePosition"]
            )
        }
        migrator.registerMigration("v2_isTestFlight") { db in
            guard try db.tableExists("download_task") else { return }
            let hasColumn = try db.columns(in: "download_task").contains { $0.name == "isTestFlight" }
            guard !hasColumn else { return }
            try db.alter(table: "download_task") { table in
                table.add(column: "isTestFlight", .boolean).notNull().defaults(to: false)
            }
        }
        return migrator
    }

    var isAvailable: Bool { dbQueue != nil }

    func save(_ data: DownloadTasksSaveData) {
        guard let dbQueue else { return }
        let records = Self.records(from: data)
        try? dbQueue.write { db in
            try DownloadTaskRecord.deleteAll(db)
            for record in records {
                try record.insert(db)
            }
        }
    }

    func load() -> DownloadTasksSaveData? {
        guard let dbQueue else { return nil }
        let records = (try? dbQueue.read { db in
            try DownloadTaskRecord.fetchAll(db)
        }) ?? []
        guard !records.isEmpty else { return nil }
        return Self.saveData(from: records)
    }

    private static func records(from data: DownloadTasksSaveData) -> [DownloadTaskRecord] {
        let completed = Set(data.completedRequests)
        let active = Set(data.activeDownloads)
        let waiting = Set(data.waitingDownloads ?? [])

        var positions: [UUID: Int] = [:]
        for (index, id) in (data.queueOrder ?? []).enumerated() {
            positions[id] = index
        }

        return data.downloadRequests.map { request in
            DownloadTaskRecord(
                id: request.id.uuidString,
                bundleIdentifier: request.bundleIdentifier,
                version: request.version,
                name: request.name,
                packageIdentifier: request.packageIdentifier,
                packageIconURL: request.packageIconURL,
                packagePrice: request.packagePrice,
                packageCurrency: request.packageCurrency,
                versionId: request.versionId,
                status: request.runtime.status.rawValue,
                progress: request.runtime.progressValue,
                error: request.runtime.error,
                speed: request.runtime.speed,
                localFilePath: request.runtime.localFilePath,
                createdAt: request.createdAt.timeIntervalSince1970,
                isCompleted: completed.contains(request.id),
                isActive: active.contains(request.id),
                isWaiting: waiting.contains(request.id),
                isTestFlight: request.packageIsTestFlight ?? false,
                queuePosition: positions[request.id]
            )
        }
    }

    private static func saveData(from records: [DownloadTaskRecord]) -> DownloadTasksSaveData {
        let ordered = records.sorted {
            ($0.queuePosition ?? Int.max) < ($1.queuePosition ?? Int.max)
        }

        let requests: [DownloadRequestSaveData] = ordered.compactMap { record in
            guard let id = UUID(uuidString: record.id),
                  let status = DownloadStatus(rawValue: record.status) else { return nil }

            return DownloadRequestSaveData(
                id: id,
                bundleIdentifier: record.bundleIdentifier,
                version: record.version,
                name: record.name,
                package: DownloadArchive(
                    bundleIdentifier: record.bundleIdentifier,
                    name: record.name,
                    version: record.version,
                    identifier: record.packageIdentifier,
                    iconURL: record.packageIconURL,
                    price: record.packagePrice,
                    currency: record.packageCurrency,
                    isTestFlight: record.isTestFlight
                ),
                versionId: record.versionId,
                runtime: DownloadRuntimeSaveData(
                    status: status,
                    progressValue: record.progress,
                    error: record.error,
                    speed: record.speed,
                    localFilePath: record.localFilePath
                ),
                createdAt: Date(timeIntervalSince1970: record.createdAt)
            )
        }

        return DownloadTasksSaveData(
            downloadRequests: requests,
            completedRequests: ordered.filter(\.isCompleted).compactMap { UUID(uuidString: $0.id) },
            activeDownloads: ordered.filter(\.isActive).compactMap { UUID(uuidString: $0.id) },
            waitingDownloads: ordered.filter(\.isWaiting).compactMap { UUID(uuidString: $0.id) },
            queueOrder: ordered
                .filter { $0.queuePosition != nil }
                .compactMap { UUID(uuidString: $0.id) }
        )
    }
}
