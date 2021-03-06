//
//  CryptoCurrency.swift
//  PlatformKit
//
//  Created by AlexM on 12/5/18.
//  Copyright © 2018 Blockchain Luxembourg S.A. All rights reserved.
//

import Foundation

/// This is used to distinguish between different types of digital assets.
/// `PlatformKit` should be almost entirely `CryptoCurrency` agnostic however.
/// It's possible that we may move this along with the other `Balance` related
/// models to a separate framework called `BalanceKit`.
/// This should be used a replacement for `AssetType` which is currently defined
/// in the app target.
public enum CryptoCurrency {
    case bitcoin, bitcoinCash, ethereum, stellar
}

public extension CryptoCurrency {
    var description: String {
        switch self {
        case .bitcoin:
            return "Bitcoin"
        case .bitcoinCash:
            return "Bitcoin Cash"
        case .ethereum:
            return "Ether"
        case .stellar:
            return "Stellar"
        }
    }
    
    var symbol: String {
        switch self {
        case .bitcoin:
            return "BTC"
        case .bitcoinCash:
            return "BCH"
        case .ethereum:
            return "ETH"
        case .stellar:
            return "XLM"
        }
    }
    
    var maxDecimalPlaces: Int {
        switch self {
        case .bitcoin:
            return 8
        case .ethereum:
            return 18
        case .bitcoinCash:
            return 8
        case .stellar:
            return 7
        }
    }
    
    var maxDisplayableDecimalPlaces: Int {
        switch self {
        case .bitcoin:
            return 8
        case .ethereum:
            return 8
        case .bitcoinCash:
            return 8
        case .stellar:
            return 7
        }
    }
}
