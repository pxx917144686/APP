import XCTest
import GRDB
import SQLite3

private class EverythingObserver: TransactionObserver {
    var changedTables = Set<String>()
    
    var databaseEventObservationStrategy: DatabaseEventObservationStrategy {
        var strategy = DatabaseEventObservationStrategy.default
        strategy.requiresDatabaseEventKind = false
        return strategy
    }

    func databaseDidChange(with event: GRDB.DatabaseEvent) {
        changedTables.insert(event.tableName)
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        fatalError("Should not be called since requiresDatabaseEventKind is false")
    }

    func databaseDidCommit(_ db: GRDB.Database) {}

    func databaseDidRollback(_ db: GRDB.Database) {}
}

private struct SendablePtr: @unchecked Sendable {
    let ptr: OpaquePointer
}

class DatabaseEventObservationStrategyTest: GRDBTestCase {
    func testIndirectWrite() throws {
        var config = Configuration()
        config.prepareDatabase{ database in
            // Replicate what a native SQLite extension might do, running statements in a user-defined functions
            let ptr = SendablePtr(ptr: database.sqliteConnection!)

            database.add(function: DatabaseFunction("custom_clear_function", function: { values in
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(ptr.ptr, "DELETE FROM foo", nil, nil, &err)
                if rc != 0 {
                    let msg = String(cString: err!)
                    fatalError(msg)
                }
                return rc
            }))
        }
        let db = try makeDatabaseQueue(configuration: config)
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE foo (bar TEXT)")
            try db.execute(sql: "INSERT INTO foo DEFAULT VALUES")
        }
        
        let observer = EverythingObserver()
        db.add(transactionObserver: observer)
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "SELECT custom_clear_function()")
        }
        
        XCTAssert(observer.changedTables == ["foo"])
    }

    func testDisablesTruncateOptimization() throws {
        let db = try makeDatabaseQueue()
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE foo (bar TEXT)")
            try db.execute(sql: "INSERT INTO foo DEFAULT VALUES")
        }
        
        let observer = EverythingObserver()
        db.add(transactionObserver: observer)
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM foo")
        }
        
        XCTAssert(observer.changedTables == ["foo"])
    }
}
