/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import FxAUtils
import RxSwift
import RxCocoa
import RxOptional
import Shared
import Storage
import SwiftyJSON
import SwiftKeychainWrapper

enum SyncError: Error {
    case CryptoInvalidKey
    case CryptoMissingKey
    case Crypto
    case Locked
    case Offline
    case Network
    case NeedAuth
    case Conflict
    case AccountDeleted
    case AccountReset
    case DeviceRevoked
}

enum SyncState: Equatable {
    case NotSyncable, ReadyToSync, Syncing, Synced, Error(error: SyncError)

    public static func ==(lhs: SyncState, rhs: SyncState) -> Bool {
        switch (lhs, rhs) {
        case (NotSyncable, NotSyncable):
            return true
        case (ReadyToSync, ReadyToSync):
            return true
        case (Syncing, Syncing):
            return true
        case (Synced, Synced):
            return true
        case (Error, Error):
            return true
        default:
            return false
        }
    }
}

enum LoginStoreState: Equatable {
    case Unprepared, Locked, Unlocked, Errored(cause: LoginStoreError)

    public static func ==(lhs: LoginStoreState, rhs: LoginStoreState) -> Bool {
        switch (lhs, rhs) {
        case (Unprepared, Unprepared): return true
        case (Locked, Locked): return true
        case (Unlocked, Unlocked): return true
        case (Errored, Errored): return true
        default:
            return false
        }
    }
}

public enum LoginStoreError: Error {
    // applies to just about every function call
    case Unknown(cause: Error?)
    case NotInitialized
    case AlreadyInitialized
    case VersionMismatch
    case CryptoInvalidKey
    case CryptoMissingKey
    case Crypto
    case InvalidItem
    case Locked
}

public typealias ProfileFactory = (_ reset: Bool) -> Profile

private let defaultProfileFactory: ProfileFactory = { reset in
    BrowserProfile(localName: "lockbox-profile", clear: reset)
}
private let lockedKey = "application_locked_state"

class DataStore {
    public static let shared = DataStore()
    private let disposeBag = DisposeBag()
    private var listSubject = BehaviorRelay<[Login]>(value: [])
    private var syncSubject = ReplaySubject<SyncState>.create(bufferSize: 1)
    private var storageStateSubject = ReplaySubject<LoginStoreState>.create(bufferSize: 1)

    private let fxaLoginHelper: FxALoginHelper
    private let profileFactory: ProfileFactory
    private let keychainWrapper: KeychainWrapper
    private var profile: Profile

    public var list: Observable<[Login]> {
        return self.listSubject.asObservable()
    }

    public var syncState: Observable<SyncState> {
        return self.syncSubject.asObservable()
    }

    public var locked: Observable<Bool> {
        return self.storageState.map { $0 == LoginStoreState.Locked }
    }

    public var storageState: Observable<LoginStoreState> {
        return self.storageStateSubject.asObservable()
    }

    init(dispatcher: Dispatcher = Dispatcher.shared,
         profileFactory: @escaping ProfileFactory = defaultProfileFactory,
         fxaLoginHelper: FxALoginHelper = FxALoginHelper.sharedInstance,
         keychainWrapper: KeychainWrapper = KeychainWrapper.standard) {
        self.profileFactory = profileFactory
        self.fxaLoginHelper = fxaLoginHelper
        self.keychainWrapper = keychainWrapper

        self.profile = profileFactory(false)
        self.initializeProfile()
        self.registerNotificationCenter()

        dispatcher.register
                .filterByType(class: DataStoreAction.self)
                .subscribe(onNext: { action in
                    switch action {
                    case let .initialize(blob:data):
                        self.login(data)
                    case .reset:
                        self.reset()
                    case .sync:
                        self.sync()
                    case let .touch(id:id):
                        self.touch(id: id)
                    case .lock:
                        self.lock()
                    case .unlock:
                        self.unlock()
                    case let .add(item: login):
                        self.add(item: login)
                    case let .remove(id:id):
                        self.remove(id: id)
                    }
                })
                .disposed(by: self.disposeBag)

        dispatcher.register
                .filterByType(class: LifecycleAction.self)
                .subscribe(onNext: { action in
                    switch action {
                    case .background:
                        self.profile.syncManager?.applicationDidEnterBackground()
                    case .foreground:
                        self.profile.syncManager?.applicationDidBecomeActive()
                    case .startup:
                        break
                    }
                })
                .disposed(by: disposeBag)

        self.syncState
                .subscribe(onNext: { state in
                    if state == .Synced {
                        self.updateList()
                    } else if state == .NotSyncable {
                        self.makeEmptyList()
                    }
                })
                .disposed(by: self.disposeBag)

        self.storageState
                .subscribe(onNext: { state in
                    if state == .Unlocked {
                        self.updateList()
                    } else if state == .Locked {
                        self.makeEmptyList()
                    }
                })
                .disposed(by: self.disposeBag)

        self.setInitialSyncState()
        self.setInitialLockState()
    }

    public func get(_ id: String) -> Observable<Login?> {
        return self.listSubject
                .map { items -> Login? in
                    return items.filter { item in
                        return item.guid == id
                    }.first
                }.asObservable()
    }
}

extension DataStore {
    public func login(_ data: JSON) {
        self.fxaLoginHelper.application(UIApplication.shared, didReceiveAccountJSON: data)
    }
}

extension DataStore {
    public func touch(id: String) {
        self.profile.logins.addUseOfLoginByGUID(id)
    }
}

extension DataStore {
    private func reset() {
        func stopSyncing() -> Success {
            guard let syncManager = self.profile.syncManager else {
                return succeed()
            }
            syncManager.endTimedSyncs()
            if !syncManager.isSyncing {
                return succeed()
            }

            return syncManager.syncEverything(why: .backgrounded)
        }

        func disconnect() -> Success {
            return self.fxaLoginHelper.applicationDidDisconnect(UIApplication.shared)
        }

        func deleteAll() -> Success {
            return self.profile.logins.removeAll()
        }

        func resetProfile() {
            self.profile = profileFactory(true)
            self.initializeProfile()
            self.syncSubject.onNext(.NotSyncable)
        }

        self.keychainWrapper.removeObject(forKey: lockedKey)

        stopSyncing() >>== disconnect >>== deleteAll >>== resetProfile
    }
}

extension DataStore {
    func lock() {
        guard !self.profile.isShutdown else {
            return
        }

        guard self.profile.hasSyncableAccount() else {
            return
        }

        self.profile.syncManager?.endTimedSyncs()

        func finalShutdown() {
            self.profile.shutdown()
            self.storageStateSubject.onNext(.Locked)
            self.keychainWrapper.set(true, forKey: lockedKey)
        }

        if self.profile.syncManager.isSyncing {
            self.profile.syncManager.syncEverything(why: .backgrounded) >>== finalShutdown
        } else {
            finalShutdown()
        }
    }

    public func unlock() {
        self.profile.reopen()

        self.profile.syncManager?.beginTimedSyncs()

        self.profile.syncManager.syncEverything(why: .startup)

        self.storageStateSubject.onNext(.Unlocked)
        self.keychainWrapper.set(false, forKey: lockedKey)
    }
}

extension DataStore {
    public func sync() {
        self.profile.syncManager.syncEverything(why: .syncNow)
    }

    private func registerNotificationCenter() {
        let names = [NotificationNames.FirefoxAccountVerified,
                     NotificationNames.ProfileDidStartSyncing,
                     NotificationNames.ProfileDidFinishSyncing
        ]
        names.forEach { name in
            NotificationCenter.default.rx
                    .notification(name)
                    .subscribe(onNext: { self.updateSyncState(from: $0) })
                    .disposed(by: self.disposeBag)
        }
    }

    private func updateSyncState(from notification: Notification) {
        let state: SyncState
        switch notification.name {
        case NotificationNames.FirefoxAccountVerified:
            state = .ReadyToSync
        case NotificationNames.ProfileDidStartSyncing:
            state = .Syncing
        case NotificationNames.ProfileDidFinishSyncing:
            state = .Synced
        default:
            return
        }
        self.syncSubject.onNext(state)
    }

    private func updateList() {
        let logins = self.profile.logins
        logins.getAllLogins() >>== { (cursor: Cursor<Login>) in
            self.listSubject.accept(cursor.asArray())
        }
    }

    private func makeEmptyList() {
        self.listSubject.accept([])
    }
}

extension DataStore {
    public func remove(id: String) {
        self.profile.logins.removeLoginByGUID(id) >>== {
            self.syncSubject.onNext(.ReadyToSync)
        }
    }

    public func add(item: LoginData) {
        self.profile.logins.addLogin(item) >>== {
            self.syncSubject.onNext(.ReadyToSync)
        }
    }
}

// initialization
extension DataStore {
    private func initializeProfile() {
        self.profile.syncManager?.applicationDidBecomeActive()

        self.fxaLoginHelper.application(UIApplication.shared, didLoadProfile: profile)
    }

    private func setInitialSyncState() {
        let state: SyncState
        if !self.profile.hasSyncableAccount() {
            state = .NotSyncable
        } else {
            state = .ReadyToSync
        }

        self.syncSubject.onNext(state)
        self.updateList()
    }

    private func setInitialLockState() {
        let lockedValue = self.keychainWrapper.bool(forKey: lockedKey) ?? false
        if lockedValue {
            self.storageStateSubject.onNext(.Locked)
        } else {
            self.storageStateSubject.onNext(.Unprepared)
            self.keychainWrapper.set(false, forKey: lockedKey)
        }
    }
}
