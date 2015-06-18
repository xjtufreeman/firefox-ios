/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared

public class MockLogins: BrowserLogins, SyncableLogins {
    private var cache = [Login]()

    public init(files: FileAccessor) {
    }

    public func getLoginsForProtectionSpace(protectionSpace: NSURLProtectionSpace) -> Deferred<Result<Cursor<LoginData>>> {
        let cursor = ArrayCursor(data: cache.filter({ login in
            return login.protectionSpace.host == protectionSpace.host
        }).sorted({ (loginA, loginB) -> Bool in
            return loginA.timeLastUsed > loginB.timeLastUsed
        }).map({ login in
            return login as LoginData
        }))
        return Deferred(value: Result(success: cursor))
    }

    public func getLoginsForProtectionSpace(protectionSpace: NSURLProtectionSpace, withUsername username: String?) -> Deferred<Result<Cursor<LoginData>>> {
        let cursor = ArrayCursor(data: cache.filter({ login in
            return login.protectionSpace.host == protectionSpace.host &&
                   login.username == username
        }).sorted({ (loginA, loginB) -> Bool in
            return loginA.timeLastUsed > loginB.timeLastUsed
        }).map({ login in
            return login as LoginData
        }))
        return Deferred(value: Result(success: cursor))
    }

    // This method is only here for testing
    public func getUsageDataForLoginByGUID(guid: GUID) -> Deferred<Result<LoginUsageData>> {
        let res = cache.filter({ login in
            return login.guid == guid
        }).sorted({ (loginA, loginB) -> Bool in
            return loginA.timeLastUsed > loginB.timeLastUsed
        })[0] as LoginUsageData

        return Deferred(value: Result(success: res))
    }

    public func addLogin(login: LoginData) -> Success {
        if let index = find(cache, login as! Login) {
            return deferResult(LoginDataError(description: "Already in the cache"))
        }
        cache.append(login as! Login)
        return succeed()
    }

    public func updateLoginByGUID(guid: GUID, new: LoginData, significant: Bool) -> Success {
        // TODO
        return succeed()
    }

    public func updateLogin(login: LoginData) -> Success {
        if let index = find(cache, login as! Login) {
            cache[index].timePasswordChanged = NSDate.nowMicroseconds()
            return succeed()
        }
        return deferResult(LoginDataError(description: "Password wasn't cached yet. Can't update"))
    }

    public func addUseOfLoginByGUID(guid: GUID) -> Success {
        if let login = cache.filter({ $0.guid == guid }).first {
            login.timeLastUsed = NSDate.nowMicroseconds()
            return succeed()
        }
        return deferResult(LoginDataError(description: "Password wasn't cached yet. Can't update"))
    }

    public func removeLoginByGUID(guid: GUID) -> Success {
        let filtered = cache.filter { $0.guid != guid }
        if filtered.count == cache.count {
            return deferResult(LoginDataError(description: "Can not remove a password that wasn't stored"))
        }
        cache = filtered
        return succeed()
    }

    public func removeAll() -> Success {
        cache.removeAll(keepCapacity: false)
        return succeed()
    }

    // TODO
    public func deleteByGUID(guid: GUID, deletedAt: Timestamp) -> Success { return succeed() }
    public func applyChangedLogin(upstream: Login, timestamp: Timestamp) -> Success { return succeed() }
    public func markAsSynchronized([GUID], modified: Timestamp) -> Deferred<Result<Timestamp>> { return deferResult(0) }
    public func markAsDeleted(guids: [GUID]) -> Success { return succeed() }
    public func onRemovedAccount() -> Success { return succeed() }
}