/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import RxSwift
import RxCocoa
import RxDataSources
import Storage
import Shared

protocol ItemListViewProtocol: class, AlertControllerView, SpinnerAlertView {
    func bind(items: Driver<[ItemSectionModel]>)
    func bind(sortingButtonTitle: Driver<String>)
    var sortingButtonEnabled: AnyObserver<Bool>? { get }
    var tableViewInteractionEnabled: AnyObserver<Bool> { get }
    func displayEmptyStateMessaging()
    func hideEmptyStateMessaging()
    func dismissKeyboard()
    func displayFilterCancelButton()
    func hideFilterCancelButton()
}

struct LoginListTextSort {
    let logins: [Login]
    let text: String
    let sortingOption: ItemListSortingAction
    let syncState: SyncState
}

extension LoginListTextSort: Equatable {
    static func ==(lhs: LoginListTextSort, rhs: LoginListTextSort) -> Bool {
        return lhs.logins == rhs.logins &&
                lhs.text == rhs.text &&
                lhs.sortingOption == rhs.sortingOption &&
                lhs.syncState == rhs.syncState
    }
}

class ItemListPresenter {
    private weak var view: ItemListViewProtocol?
    private var routeActionHandler: RouteActionHandler
    private var itemListDisplayActionHandler: ItemListDisplayActionHandler
    private var dataStoreActionHandler: DataStoreActionHandler
    private var dataStore: DataStore
    private var itemListDisplayStore: ItemListDisplayStore
    private var disposeBag = DisposeBag()

    lazy private(set) var itemSelectedObserver: AnyObserver<String?> = {
        return Binder(self) { target, itemId in
            guard let id = itemId else {
                return
            }

            target.routeActionHandler.invoke(MainRouteAction.detail(itemId: id))
        }.asObserver()
    }()

    lazy private(set) var onSettingsTapped: AnyObserver<Void> = {
        return Binder(self) { target, _ in
            target.routeActionHandler.invoke(SettingRouteAction.list)
        }.asObserver()
    }()

    lazy private(set) var filterTextObserver: AnyObserver<String> = {
        return Binder(self) { target, filterText in
            target.itemListDisplayActionHandler.invoke(ItemListFilterAction(filteringText: filterText))
        }.asObserver()
    }()

    lazy private(set) var filterCancelObserver: AnyObserver<Void> = {
        return Binder(self) { target, _ in
            target.dismissKeyboard()
        }.asObserver()
    }()

    lazy private(set) var refreshObserver: AnyObserver<Void> = {
        return Binder(self) { target, _ in
            target.dataStoreActionHandler.invoke(.sync)
        }.asObserver()
    }()

    lazy private(set) var sortingButtonObserver: AnyObserver<Void> = {
        return Binder(self) { target, _ in
            target.view?.displayAlertController(buttons: [
                AlertActionButtonConfiguration(
                        title: Constant.string.alphabetically,
                        tapObserver: target.alphabeticSortObserver,
                        style: .default),
                AlertActionButtonConfiguration(
                        title: Constant.string.recentlyUsed,
                        tapObserver: target.recentlyUsedSortObserver,
                        style: .default),
                AlertActionButtonConfiguration(
                        title: Constant.string.cancel,
                        tapObserver: nil,
                        style: .cancel)],
                    title: Constant.string.sortEntries,
                    message: nil,
                    style: .actionSheet)
        }.asObserver()
    }()

    lazy private var alphabeticSortObserver: AnyObserver<Void> = {
        return Binder(self) { target, _ in
            target.itemListDisplayActionHandler.invoke(ItemListSortingAction.alphabetically)
        }.asObserver()
    }()

    lazy private var recentlyUsedSortObserver: AnyObserver<Void> = {
        return Binder(self) { target, _ in
            target.itemListDisplayActionHandler.invoke(ItemListSortingAction.recentlyUsed)
        }.asObserver()
    }()

    lazy private var syncPlaceholderItems = [
        ItemSectionModel(model: 0, items: [
            LoginListCellConfiguration.Search,
            LoginListCellConfiguration.ListPlaceholder
        ])
    ]

    init(view: ItemListViewProtocol,
         routeActionHandler: RouteActionHandler = RouteActionHandler.shared,
         itemListDisplayActionHandler: ItemListDisplayActionHandler = ItemListDisplayActionHandler.shared,
         dataStoreActionHandler: DataStoreActionHandler = DataStoreActionHandler.shared,
         dataStore: DataStore = DataStore.shared,
         itemListDisplayStore: ItemListDisplayStore = ItemListDisplayStore.shared) {
        self.view = view
        self.routeActionHandler = routeActionHandler
        self.itemListDisplayActionHandler = itemListDisplayActionHandler
        self.dataStoreActionHandler = dataStoreActionHandler
        self.dataStore = dataStore
        self.itemListDisplayStore = itemListDisplayStore
    }

    func onViewReady() {
        let itemListObservable = self.placeholderComputingItemListObservable()

        let itemSortObservable = self.itemListDisplayStore.listDisplay
                .filterByType(class: ItemListSortingAction.self)

        let filterTextObservable = self.itemListDisplayStore.listDisplay
                .filterByType(class: ItemListFilterAction.self)
                .do(onNext: { filterAction in
                    if filterAction.filteringText.isEmpty {
                        self.view?.hideFilterCancelButton()
                    } else {
                        self.view?.displayFilterCancelButton()
                    }
                })

        let listDriver = self.createItemListDriver(
                loginListObservable: itemListObservable,
                filterTextObservable: filterTextObservable,
                itemSortObservable: itemSortObservable,
                syncStateObservable: self.dataStore.syncState
        )

        self.view?.bind(items: listDriver)

        let itemSortTextDriver = itemSortObservable
                .asDriver(onErrorJustReturn: .alphabetically)
                .map { itemSortAction -> String in
                    switch itemSortAction {
                    case .alphabetically:
                        return Constant.string.aToZ
                    case .recentlyUsed:
                        return Constant.string.recent
                    }
                }

        self.view?.bind(sortingButtonTitle: itemSortTextDriver)

        self.itemListDisplayActionHandler.invoke(ItemListSortingAction.alphabetically)
        self.itemListDisplayActionHandler.invoke(ItemListFilterAction(filteringText: ""))

        guard let view = self.view,
              let sortButtonObserver = view.sortingButtonEnabled else {
            return
        }

        let enableObservable = Observable.combineLatest(self.dataStore.syncState, self.dataStore.list)
                .map {
                    $0.0 != SyncState.Syncing && !$0.1.isEmpty
                }

        enableObservable.bind(to: sortButtonObserver).disposed(by: self.disposeBag)
        enableObservable.bind(to: view.tableViewInteractionEnabled).disposed(by: self.disposeBag)
    }
}

extension ItemListPresenter {
    fileprivate func createItemListDriver(loginListObservable: Observable<[Login]>,
                                          filterTextObservable: Observable<ItemListFilterAction>,
                                          itemSortObservable: Observable<ItemListSortingAction>,
                                          syncStateObservable: Observable<SyncState>) -> Driver<[ItemSectionModel]> {
        return Observable.combineLatest(
                        loginListObservable,
                        filterTextObservable,
                        itemSortObservable,
                        syncStateObservable
                )
                .map { (latest: ([Login], ItemListFilterAction, ItemListSortingAction, SyncState)) -> LoginListTextSort in
                    return LoginListTextSort(
                            logins: latest.0,
                            text: latest.1.filteringText,
                            sortingOption: latest.2,
                            syncState: latest.3
                    )
                }
                .distinctUntilChanged()
                .map { (latest: LoginListTextSort) -> [ItemSectionModel] in
                    if (latest.syncState == .Syncing || latest.syncState == .ReadyToSync) && latest.logins.isEmpty {
                        return self.syncPlaceholderItems
                    }

                    let sortedFilteredItems = self.filterItemsForText(latest.text, items: latest.logins)
                            .sorted { lhs, rhs -> Bool in
                                switch latest.sortingOption {
                                case .alphabetically:
                                    return lhs.hostname < rhs.hostname
                                case .recentlyUsed:
                                    return lhs.timeLastUsed > rhs.timeLastUsed
                                }
                            }

                    return [ItemSectionModel(model: 0, items: self.configurationsFromItems(sortedFilteredItems))]
                }
                .asDriver(onErrorJustReturn: [])
    }

    private func placeholderComputingItemListObservable() -> Observable<[Login]> {
        // when this observable emits an event, the spinner gets dismissed
        let hideSpinnerObservable = self.dataStore.syncState
                .filter {
                    $0 == SyncState.Synced
                }
                .map { _ in
                    return ()
                }
                .asDriver(onErrorJustReturn: ())

        return Observable.combineLatest(self.dataStore.list, self.dataStore.syncState)
                .asDriver(onErrorJustReturn: ([], SyncState.Synced))
                .do(onNext: { latest in
                    if latest.0.isEmpty && latest.1 == SyncState.Synced {
                        self.view?.displayEmptyStateMessaging()
                    }

                    if latest.1 == SyncState.Syncing {
                        self.view?.displaySpinner(hideSpinnerObservable, bag: self.disposeBag)
                    }

                    if !latest.0.isEmpty {
                        self.view?.hideEmptyStateMessaging()
                    }
                })
                .asObservable()
                .filter { latest in
                    return !(latest.0.isEmpty && latest.1 == SyncState.Synced)
                }
                .map {
                    $0.0
                }
    }

    fileprivate func configurationsFromItems(_ items: [Login]) -> [LoginListCellConfiguration] {
        let searchCell = [LoginListCellConfiguration.Search]

        let loginCells = items.map { login -> LoginListCellConfiguration in
            let titleText = self.titleFromHostname(login.hostname)
            let usernameEmpty = login.username == "" || login.username == nil
            let usernameText = usernameEmpty ? Constant.string.usernamePlaceholder : login.username!

            return LoginListCellConfiguration.Item(title: titleText, username: usernameText, guid: login.guid)
        }

        return searchCell + loginCells
    }

    fileprivate func filterItemsForText(_ text: String, items: [Login]) -> [Login] {
        if text.isEmpty {
            return items
        }

        return items.filter { item -> Bool in
            return [item.username, self.titleFromHostname(item.hostname)]
                    .compactMap {
                        $0?.localizedCaseInsensitiveContains(text) ?? false
                    }
                    .reduce(false) {
                        $0 || $1
                    }
        }
    }

    private func titleFromHostname(_ hostname: String) -> String {
        return hostname
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
    }

    func dismissKeyboard() {
        view?.dismissKeyboard()
    }
}
