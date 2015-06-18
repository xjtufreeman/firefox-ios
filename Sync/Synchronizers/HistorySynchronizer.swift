/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage
import XCGLogger

private let log = XCGLogger.defaultInstance()
private let HistoryTTLInSeconds = 5184000                   // 60 days.
private let HistoryStorageVersion = 1

func makeDeletedHistoryRecord(guid: GUID) -> Record<HistoryPayload> {
    // Local modified time is ignored in upload serialization.
    let modified: Timestamp = 0

    // Sortindex for history is frecency. Make deleted items more frecent than almost
    // anything.
    let sortindex = 5_000_000

    let ttl = HistoryTTLInSeconds

    let json: JSON = JSON([
        "id": guid,
        "deleted": true,
        ])
    let payload = HistoryPayload(json)
    return Record<HistoryPayload>(id: guid, payload: payload, modified: modified, sortindex: sortindex, ttl: ttl)
}

func makeHistoryRecord(place: Place, visits: [Visit]) -> Record<HistoryPayload> {
    let id = place.guid
    let modified: Timestamp = 0    // Ignored in upload serialization.
    let sortindex = 1              // TODO: frecency!
    let ttl = HistoryTTLInSeconds
    let json: JSON = JSON([
        "id": id,
        "visits": visits.map { $0.toJSON() },
        "histUri": place.url,
        "title": place.title,
        ])
    let payload = HistoryPayload(json)
    return Record<HistoryPayload>(id: id, payload: payload, modified: modified, sortindex: sortindex, ttl: ttl)
}

public class HistorySynchronizer: IndependentRecordSynchronizer, Synchronizer {
    public required init(scratchpad: Scratchpad, delegate: SyncDelegate, basePrefs: Prefs) {
        super.init(scratchpad: scratchpad, delegate: delegate, basePrefs: basePrefs, collection: "history")
    }

    override var storageVersion: Int {
        return HistoryStorageVersion
    }

    // TODO: this function should establish a transaction at suitable points.
    // TODO: a much more efficient way to do this is to:
    // 1. Start a transaction.
    // 2. Try to update each place. Note failures.
    // 3. bulkInsert all failed updates in one go.
    // 4. Store all remote visits for all places in one go, constructing a single sequence of visits.
    func applyIncomingToStorage(storage: SyncableHistory, records: [Record<HistoryPayload>], fetched: Timestamp) -> Success {

        // TODO: it'd be nice to put this in an extension on SyncableHistory. Waiting for Swift 2.0...
        func applyRecord(rec: Record<HistoryPayload>) -> Success {
            let guid = rec.id
            let payload = rec.payload
            let modified = rec.modified

            // We apply deletions immediately. Yes, this will throw away local visits
            // that haven't yet been synced. That's how Sync works, alas.
            if payload.deleted {
                return storage.deleteByGUID(guid, deletedAt: modified)
            }

            // It's safe to apply other remote records, too -- even if we re-download, we know
            // from our local cached server timestamp on each record that we've already seen it.
            // We have to reconcile on-the-fly: we're about to overwrite the server record, which
            // is our shared parent.
            let place = rec.payload.asPlace()
            let placeThenVisits = storage.insertOrUpdatePlace(place, modified: modified)
                              >>> { storage.storeRemoteVisits(payload.visits, forGUID: guid) }
            return placeThenVisits.map({ result in
                if result.isFailure {
                    log.error("Record application failed: \(result.failureValue)")
                }
                return result
            })
        }

        return self.applyIncomingToStorage(records, fetched: fetched, apply: applyRecord)
    }

    private func uploadModifiedPlaces(places: [(Place, [Visit])], lastTimestamp: Timestamp, fromStorage storage: SyncableHistory, withServer storageClient: Sync15CollectionClient<HistoryPayload>) -> DeferredTimestamp {
        return self.uploadRecords(places.map(makeHistoryRecord), by: 50, lastTimestamp: lastTimestamp, storageClient: storageClient, onUpload: { storage.markAsSynchronized($0, modified: $1) })
    }

    private func uploadDeletedPlaces(guids: [GUID], lastTimestamp: Timestamp, fromStorage storage: SyncableHistory, withServer storageClient: Sync15CollectionClient<HistoryPayload>) -> DeferredTimestamp {

        let records = guids.map(makeDeletedHistoryRecord)

        // Deletions are smaller, so upload 100 at a time.
        return self.uploadRecords(records, by: 100, lastTimestamp: lastTimestamp, storageClient: storageClient, onUpload: { storage.markAsDeleted($0) >>> always($1) })
    }

    private func uploadOutgoingFromStorage(storage: SyncableHistory, lastTimestamp: Timestamp, withServer storageClient: Sync15CollectionClient<HistoryPayload>) -> Success {

        let uploadDeleted: Timestamp -> DeferredTimestamp = { timestamp in
            storage.getDeletedHistoryToUpload()
            >>== { guids in
                return self.uploadDeletedPlaces(guids, lastTimestamp: timestamp, fromStorage: storage, withServer: storageClient)
            }
        }

        let uploadModified: Timestamp -> DeferredTimestamp = { timestamp in
            storage.getModifiedHistoryToUpload()
                >>== { places in
                    return self.uploadModifiedPlaces(places, lastTimestamp: timestamp, fromStorage: storage, withServer: storageClient)
            }
        }

        return deferResult(lastTimestamp)
          >>== uploadDeleted
          >>== uploadModified
           >>> effect({ log.debug("Done syncing.") })
           >>> succeed
    }

    public func synchronizeLocalHistory(history: SyncableHistory, withServer storageClient: Sync15StorageClient, info: InfoCollections) -> SyncResult {
        if let reason = self.reasonToNotSync(storageClient) {
            return deferResult(.NotStarted(reason))
        }

        let encoder = RecordEncoder<HistoryPayload>(decode: { HistoryPayload($0) }, encode: { $0 })
        if let historyClient = self.collectionClient(encoder, storageClient: storageClient) {
            let since: Timestamp = self.lastFetched
            log.debug("Synchronizing \(self.collection). Last fetched: \(since).")

            // TODO: buffer downloaded records, fetching incrementally, so that we can separate
            // the network fetch from record application.

            let applyIncomingToStorage: StorageResponse<[Record<HistoryPayload>]> -> Success = { response in
                let ts = response.metadata.timestampMilliseconds
                let lm = response.metadata.lastModifiedMilliseconds!
                log.debug("Applying incoming history records from response timestamped \(ts), last modified \(lm).")
                log.debug("Records header hint: \(response.metadata.records)")
                return self.applyIncomingToStorage(history, records: response.value, fetched: lm)
            }

            return historyClient.getSince(since)
              >>== applyIncomingToStorage
                // TODO: If we fetch sorted by date, we can bump the lastFetched timestamp
                // to the last successfully applied record timestamp, no matter where we fail.
                // There's no need to do the upload before bumping -- the storage of local changes is stable.
               >>> { self.uploadOutgoingFromStorage(history, lastTimestamp: 0, withServer: historyClient) }
               >>> { return deferResult(.Completed) }
        }

        log.error("Couldn't make history factory.")
        return deferResult(FatalError(message: "Couldn't make history factory."))
    }
}
