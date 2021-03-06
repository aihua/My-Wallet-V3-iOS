//
//  HistoricalTransactionAPI.swift
//  PlatformKit
//
//  Created by Alex McGregor on 11/12/18.
//  Copyright © 2018 Blockchain Luxembourg S.A. All rights reserved.
//

import Foundation
import RxSwift

/// `HistoricalTransactionAPI` is used for fetching transactions that the user has already submitted.
/// It returns a `PageResult<HistoricalTransaction>`. Depending on what asset type you are requesting
/// the page size may vary. 
public protocol HistoricalTransactionAPI {
    typealias AccountID = String
    associatedtype Model: HistoricalTransaction
    func fetchTransactions(from accountID: AccountID, token: String?, size: Int) -> Observable<PageResult<Model>>
}
