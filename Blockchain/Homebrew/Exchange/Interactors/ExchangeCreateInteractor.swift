//
//  ExchangeCreateInteractor.swift
//  Blockchain
//
//  Created by kevinwu on 8/28/18.
//  Copyright © 2018 Blockchain Luxembourg S.A. All rights reserved.
//

import Foundation
import RxSwift

class ExchangeCreateInteractor {

    weak var output: ExchangeCreateOutput? {
        didSet {
            // output is not set during ExchangeCreateInteractor initialization,
            // so the first update to the trading pair view is done here
            didSetModel(oldModel: nil)
        }
    }

    private let disposables = CompositeDisposable()
    private var tradingLimitDisposable: Disposable?

    fileprivate let inputs: ExchangeInputsAPI
    fileprivate let markets: ExchangeMarketsAPI
    fileprivate let conversions: ExchangeConversionAPI
    fileprivate let tradeExecution: TradeExecutionAPI
    fileprivate let tradeLimitService: TradeLimitsAPI
    private(set) var model: MarketsModel? {
        didSet {
            didSetModel(oldModel: oldValue)
        }
    }

    init(dependencies: ExchangeDependencies, model: MarketsModel) {
        self.markets = dependencies.markets
        self.inputs = dependencies.inputs
        self.conversions = dependencies.conversions
        self.tradeExecution = dependencies.tradeExecution
        self.tradeLimitService = dependencies.tradeLimits
        self.model = model
    }

    func didSetModel(oldModel: MarketsModel?) {
        // TICKET: IOS-1287 - This should be called after user has stopped typing
        if markets.hasAuthenticated {
            updateMarketsConversion()
        }

        // Only update TradingPair in Trading Pair View if it is different
        // from the old TradingPair
        guard let model = model else { return }

        if let oldModel = oldModel {
            if oldModel.pair != model.pair || oldModel.fix != model.fix {
                output?.updateTradingPair(pair: model.pair, fix: model.fix)
            }
        } else {
            output?.updateTradingPair(pair: model.pair, fix: model.fix)
        }
    }

    deinit {
        tradingLimitDisposable?.dispose()
        tradingLimitDisposable = nil
        
        disposables.dispose()
    }
}

extension ExchangeCreateInteractor: ExchangeCreateInput {

    fileprivate enum TradingLimit {
        case min
        case max
    }

    fileprivate enum ExchangeCreateError {
        case aboveTradingLimit
        case belowTradingLimit
        case unknown

        init(errorCode: NabuNetworkErrorCode) {
            switch errorCode {
            case .tooBigVolume:
                self = .aboveTradingLimit
            case .tooSmallVolume:
                self = .belowTradingLimit
            case .resultCurrencyRatioTooSmall:
                self = .belowTradingLimit
            default:
                self = .unknown
            }
        }

        var message: String {
            switch self {
            case .aboveTradingLimit: return LocalizationConstants.Exchange.aboveTradingLimit
            case .belowTradingLimit: return LocalizationConstants.Exchange.belowTradingLimit
            case .unknown: return LocalizationConstants.Errors.error
            }
        }
    }
    
    func viewLoaded() {
        guard let output = output else { return }
        guard let model = model else { return }
        inputs.setup(with: output.styleTemplate(), usingFiat: model.isUsingFiat)
        
        updatedInput()
        
        markets.setup()

        // Authenticate, then listen for conversions
        markets.authenticate(completion: { [unowned self] in
            self.tradeLimitService.initialize(withFiatCurrency: model.fiatCurrencyCode)
            self.subscribeToConversions()
            self.updateMarketsConversion()
            self.subscribeToBestRates()
        })
    }

    func updateMarketsConversion() {
        guard let model = model else {
            Logger.shared.error("Updating conversion with no model")
            return
        }
        markets.updateConversion(model: model)
    }

    func updatedInput() {
        // Update model volume
        guard let model = model else {
            Logger.shared.error("Updating input with no model")
            return
        }
        model.volume = inputs.activeInput

        // Update interface to reflect what has been typed
        updateOutput()

        // Re-subscribe to socket with new volume value
        updateMarketsConversion()
    }

    func updateOutput() {
        // Update the inputs in crypto and fiat
        guard let output = output else { return }
        guard let model = model else { return }
        let symbol = model.fiatCurrencySymbol
        let suffix = model.pair.from.symbol
        
        let secondaryAmount = conversions.output == "0" ? "0.00": conversions.output
        let secondaryResult = model.isUsingFiat ? (secondaryAmount + " " + suffix) : (symbol + secondaryAmount)
        let primaryOffset = inputs.estimatedSymbolWidth(currencySymbol: symbol, template: output.styleTemplate())

        if model.isUsingFiat {
            let primary = inputs.primaryFiatAttributedString(currencySymbol: symbol)
            output.updatedInput(primary: primary, secondary: secondaryResult, primaryOffset: -primaryOffset)
        } else {
            let assetType = model.isUsingBase ? model.pair.from : model.pair.to
            let symbol = assetType.symbol
            let primary = inputs.primaryAssetAttributedString(symbol: symbol)
            output.updatedInput(primary: primary, secondary: secondaryResult, primaryOffset: -primaryOffset)
        }
    }

    func updateTradingValues(left: String, right: String) {
        output?.updateTradingPairValues(left: left, right: right)
    }

    func displayInputTypeTapped() {
        guard let model = model else { return }
        model.toggleFiatInput()
        inputs.isUsingFiat = model.isUsingFiat
        inputs.toggleInput(withOutput: conversions.output)
        updatedInput()
    }
    
    func useMinimumAmount(assetAccount: AssetAccount) {
        applyTradingLimit(limit: .min, assetAccount: assetAccount)
    }
    
    func useMaximumAmount(assetAccount: AssetAccount) {
        applyTradingLimit(limit: .max, assetAccount: assetAccount)
    }

    func toggleFix() {
        guard let model = model else { return }
        model.toggleFix()
        model.lastConversion = nil
        clearInputs()
        updatedInput()
        output?.updateTradingPair(pair: model.pair, fix: model.fix)
    }
    
    func onBackspaceTapped() {
        guard inputs.canBackspace() else {
            output?.entryRejected()
            return
        }

        inputs.backspace()

        // Clear conversions if the user backspaced all the way to 0
        if !inputs.canBackspace() {
            clearInputs()
        }

        updatedInput()
    }

    func onAddInputTapped(value: String) {
        guard model != nil else {
            Logger.shared.error("Updating conversion with no model")
            return
        }
        
        guard canAddAdditionalCharacter(value) == true else {
            output?.entryRejected()
            return
        }
        
        inputs.add(
            character: value
        )
        
        updatedInput()
    }
    
    func onDelimiterTapped(value: String) {
        guard inputs.canAddDelimiter() else {
            output?.entryRejected()
            return
        }
        
        guard let model = model else { return }
        
        let text = model.isUsingFiat ? "00" : value
        
        inputs.add(
            delimiter: text
        )
        
        updatedInput()
    }

    func changeMarketPair(marketPair: MarketPair) {
        guard let model = model else { return }

        // Unsubscribe from old pair conversions
        Logger.shared.debug("Unsubscribing from old currency pair '\(model.pair.stringRepresentation)'")
        markets.unsubscribeToCurrencyPair(pair: model.pair.stringRepresentation)

        // Update to new pair
        model.marketPair = marketPair
        updatedInput()
        output?.updateTradingPair(pair: model.pair, fix: model.fix)
    }
    
    func confirmationIsExecuting() -> Bool {
        return tradeExecution.isExecuting
    }

    func confirmConversion() {
        guard let model = model else { return }
        guard let conversion = model.lastConversion else {
            Logger.shared.error("No conversion stored")
            return
        }
        guard let output = output else { return }
        output.loadingVisibility(.visible)
        self.tradeExecution.prebuildOrder(
            with: conversion,
            from: model.marketPair.fromAccount,
            to: model.marketPair.toAccount,
            success: { [weak self] orderTransaction, conversion in
                guard let this = self else { return }
                this.output?.loadingVisibility(.hidden)
                this.output?.showSummary(orderTransaction: orderTransaction, conversion: conversion)
            }, error: { [weak self] errorMessage in
                guard let this = self else { return }
                this.output?.showError(message: errorMessage)
                this.output?.loadingVisibility(.hidden)
            }
        )
    }

    // swiftlint:disable:next cyclomatic_complexity
    func validateInput() {
        guard let model = model else { return }
        guard let output = output else { return }
        
        let account = model.marketPair.fromAccount

        guard let conversion = model.lastConversion else {
            Logger.shared.error("No conversion stored")
            return
        }
        
        guard let volume = Decimal(string: conversion.quote.currencyRatio.base.crypto.value) else { return }
        guard let candidate = Decimal(string: conversion.baseFiatValue) else { return }
        
        guard tradeExecution.canTradeAssetType(model.pair.from) else {
            if let errorMessage = errorMessage(for: model.pair.from) {
                output.showError(message: errorMessage)
            } else {
                // This shouldn't happen because the only case (eth) should have an error message,
                // but just in case show an error here
                output.showError(message: LocalizationConstants.Errors.genericError)
            }
            return
        }
        
        /// Volume is used for XLM in this case. `tradeExecution` has
        /// references to XLM specific services so it can validate
        /// that the volume valid by using the ledger.
        /// This will return `true` for all other asset types other than `.stellar` O
        let disposable = tradeExecution.validateVolume(volume, for: model.marketPair.fromAccount)
            .asObservable()
            .flatMap { [weak self] error -> Observable<(Decimal, Decimal, Decimal?, Decimal?)> in
                guard let strongSelf = self else {
                    return Observable.empty()
                }
                if let error = error {
                    return Observable.error(error)
                }
                let min = strongSelf.minTradingLimit().asObservable()
                let max = strongSelf.maxTradingLimit().asObservable()
                let daily = strongSelf.dailyAvailable().asObservable()
                let annual = strongSelf.annualAvailable().asObservable()
                return Observable.zip(min, max, daily, annual)
            }
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { [weak self] payload in
                guard let strongSelf = self else {
                    return
                }

                let minValue = payload.0
                let maxValue = payload.1
                let daily = payload.2
                let annual = payload.3

                if account.balance < volume {
                    let symbol = conversion.baseCryptoSymbol
                    let notEnough = LocalizationConstants.Exchange.notEnough + " " + symbol + "."
                    let yourBalance = LocalizationConstants.Exchange.yourBalance + " " + "\(account.balance)" + " " + symbol
                    let value = notEnough + " " + yourBalance + "."
                    output.insufficientFunds(balance: value)
                    return
                }

                let greatestFiniteMagnitude = Decimal.greatestFiniteMagnitude

                let periodicLimit = daily ?? annual ?? 0

                switch candidate {
                case ..<minValue:
                    let formattedValue = strongSelf.formatLimit(fiatCurrencySymbol: model.fiatCurrencySymbol, value: minValue)
                    output.entryBelowMinimumValue(minimum: formattedValue)
                case periodicLimit..<greatestFiniteMagnitude:
                    let formattedValue = strongSelf.formatLimit(fiatCurrencySymbol: model.fiatCurrencySymbol, value: (daily ?? 0))
                    output.entryAboveTierLimit(amount: formattedValue)
                case maxValue..<greatestFiniteMagnitude:
                    let formattedValue = strongSelf.formatLimit(fiatCurrencySymbol: model.fiatCurrencySymbol, value: maxValue)
                    output.entryAboveMaximumValue(maximum: formattedValue)
                default:
                    output.hideError()
                    output.exchangeButtonVisibility(.visible)
                    output.exchangeButtonEnabled(true)
                }
            }, onError: { [weak self] error in
                if let tradingError = error as? TradeExecutionAPIError {
                    switch tradingError {
                    case .generic:
                        self?.output?.showError(message: LocalizationConstants.Errors.genericError)
                    case .exceededMaxVolume(let value):
                        self?.output?.showError(message: value)
                    }
                }
            })
        disposables.insertWithDiscardableResult(disposable)
    }

    // MARK: - Private
    private func formatLimit(fiatCurrencySymbol: String, value: Decimal) -> String {
        let value = NumberFormatter.localCurrencyFormatter.string(for: value) ?? ""
        let limit = fiatCurrencySymbol + value
        return limit
    }

    private func subscribeToBestRates() {
        let bestRatesDisposable = markets.bestExchangeRates()
        .subscribe(onNext: { [weak self] rates in
            guard let strongSelf = self else { return }

            guard let marketsModel = strongSelf.model else { return }

            let fiatCode = marketsModel.fiatCurrencyCode
            let baseCode = marketsModel.pair.from.symbol
            let counterCode = marketsModel.pair.to.symbol

            strongSelf.output?.updatedRates(
                first: rates.exchangeRateDescription(fromCurrency: baseCode, toCurrency: counterCode),
                second: rates.exchangeRateDescription(fromCurrency: baseCode, toCurrency: fiatCode),
                third: rates.exchangeRateDescription(fromCurrency: counterCode, toCurrency: fiatCode)
            )
        })
        disposables.insertWithDiscardableResult(bestRatesDisposable)
    }

    private func subscribeToConversions() {
        let conversionsDisposable = markets.conversions.subscribe(onNext: { [weak self] conversion in
            guard let this = self else { return }

            guard let model = this.model else { return }

            guard model.pair.stringRepresentation == conversion.quote.pair else {
                Logger.shared.warning(
                    "Pair '\(conversion.quote.pair)' is different from model pair '\(model.pair.stringRepresentation)'."
                )
                return
            }
            
            guard model.lastConversion != conversion else { return }

            // Store conversion
            model.lastConversion = conversion

            // Use conversions service to determine new input/output
            this.conversions.update(with: conversion)

            // Update interface to reflect the values returned from the conversion
            // Update input labels
            this.updateOutput()

            // Update trading pair view values
            this.updateTradingValues(left: this.conversions.baseOutput, right: this.conversions.counterOutput)

            this.validateInput()
        }, onError: { error in
            Logger.shared.error("Error subscribing to quote with trading pair")
        })

        let errorDisposable = markets.errors.subscribe(onNext: { [weak self] socketError in
            guard let this = self else { return }
            guard let model = this.model else { return }
            guard let output = this.output else { return }

            guard this.tradeExecution.canTradeAssetType(model.pair.from) else {
                if let errorMessage = this.errorMessage(for: model.pair.from) {
                    output.showError(message: errorMessage)
                } else {
                    // This shouldn't happen because the only case (eth) should have an error message,
                    // but just in case show an error here
                    output.showError(message: LocalizationConstants.Errors.genericError)
                }
                return
            }

            let symbol = model.fiatCurrencySymbol
            let suffix = model.pair.from.symbol
            
            let secondaryAmount = "0.00"
            let secondaryResult = model.isUsingFiat ? (secondaryAmount + " " + suffix) : (symbol + secondaryAmount)
            let primaryOffset = this.inputs.estimatedSymbolWidth(currencySymbol: symbol, template: output.styleTemplate())
            
            /// When users are above or below the trading limit, `conversion.output` will not be updated
            /// with the correct conversion value. This is because the volume entered is either too little
            /// or too large. In this case we want the `secondaryAmountLabel` to read as `0.00`. We don't
            /// want to update `conversion.output` manually though as that'd be a side-effect. 
            if model.isUsingFiat {
                let primary = this.inputs.primaryFiatAttributedString(currencySymbol: symbol)
                output.updatedInput(primary: primary, secondary: secondaryResult, primaryOffset: -primaryOffset)
            } else {
                let assetType = model.isUsingBase ? model.pair.from : model.pair.to
                let symbol = assetType.symbol
                let primary = this.inputs.primaryAssetAttributedString(symbol: symbol)
                output.updatedInput(primary: primary, secondary: secondaryResult, primaryOffset: -primaryOffset)
            }
            
            Logger.shared.error(socketError.description)

            switch socketError.errorType {
            case .currencyRatioError:
                let exchangeError = ExchangeCreateError(errorCode: socketError.code)
                this.output?.showError(message: exchangeError.message)
            case .default:
                this.output?.showError(message: LocalizationConstants.Errors.error)
            }
        })

        disposables.insertWithDiscardableResult(conversionsDisposable)
        disposables.insertWithDiscardableResult(errorDisposable)
    }

    private func applyValue(stringValue: String) {
        stringValue.unicodeScalars.forEach { char in
            let charStringValue = String(char)
            if CharacterSet.decimalDigits.contains(char) {
                onAddInputTapped(value: charStringValue)
            } else if "." == charStringValue {
                onDelimiterTapped(value: charStringValue)
            }
        }
    }
    
    private func minTradingLimit() -> Maybe<Decimal> {
        return tradingLimitInfo(info: { tradingLimits -> Decimal in
            return tradingLimits.minOrder
        })
    }
    
    private func maxTradingLimit() -> Maybe<Decimal> {
        return tradingLimitInfo(info: { tradingLimits -> Decimal in
            return tradingLimits.maxPossibleOrder
        })
    }

    private func dailyAvailable() -> Maybe<Decimal?> {
        guard let model = model else {
            return Maybe.empty()
        }
        return tradeLimitService.getTradeLimits(withFiatCurrency: model.fiatCurrencyCode).asMaybe().map { limits -> Decimal? in
            return limits.daily?.available
        }
    }

    private func annualAvailable() -> Maybe<Decimal?> {
        guard let model = model else {
            return Maybe.empty()
        }
        return tradeLimitService.getTradeLimits(withFiatCurrency: model.fiatCurrencyCode).asMaybe().map { limits -> Decimal? in
            return limits.annual?.available
        }
    }

    // Need to ensure that these are newly fetched after each trade
    private func tradingLimitInfo(info: @escaping (TradeLimits) -> Decimal) -> Maybe<Decimal> {
        guard let model = model else {
            return Maybe.empty()
        }
        return tradeLimitService.getTradeLimits(
            withFiatCurrency: model.fiatCurrencyCode).map { tradingLimits -> Decimal in
            return info(tradingLimits)
        }.asMaybe()
    }
    
    private func applyTradingLimit(limit: TradingLimit, assetAccount: AssetAccount) {
        guard let model = model else { return }

        // Dispose previous subscription
        tradingLimitDisposable?.dispose()

        // Update MarketsModel to baseInFiat and update view
        model.fix = .baseInFiat
        model.lastConversion = nil
        inputs.isUsingFiat = true
        clearInputs()
        output?.updateTradingPair(pair: model.pair, fix: model.fix)

        // Compute trading limit and take into account user's balance
        let tradingLimitsSingle = tradeLimitService.getTradeLimits(withFiatCurrency: model.fiatCurrencyCode)
        let balanceFiatValue = markets.fiatBalance(
            forAssetAccount: assetAccount,
            fiatCurrencyCode: model.fiatCurrencyCode
        )

        tradingLimitDisposable = Single.zip(tradingLimitsSingle, balanceFiatValue.take(1).asSingle()) {
            return ($0, $1)
        }.subscribeOn(MainScheduler.asyncInstance)
        .observeOn(MainScheduler.instance)
        .subscribe(onSuccess: { [weak self] (limits, accountFiatValue) in
            guard let strongSelf = self else { return }

            let limitInDecimal: Decimal
            switch limit {
            case .min:
                limitInDecimal = (accountFiatValue < limits.minOrder) ? accountFiatValue : limits.minOrder
            case .max:
                limitInDecimal = (accountFiatValue < limits.maxPossibleOrder) ? accountFiatValue : limits.maxPossibleOrder
            }

            guard let limitString = NumberFormatter.localCurrencyFormatter.string(for: limitInDecimal) else { return }
            strongSelf.applyValue(stringValue: limitString)
        }, onError: { error in
            Logger.shared.error("Failed to compute trading limits: \(error)")
        })
    }

    private func clearInputs() {
        inputs.clear()
        conversions.clear()
        output?.updateTradingPairValues(left: "", right: "")
    }

    fileprivate func canAddAdditionalCharacter(_ value: String) -> Bool {
        guard let model = model else { return false }
        switch model.isUsingFiat {
        case true:
            return inputs.canAddFiatCharacter(value)
        case false:
            let assetType = model.isUsingBase ? model.pair.from : model.pair.to
            return inputs.canAddAssetCharacter(value, type: assetType)
        }
    }

    // Error message to show if the user is not allowed to trade a certain asset type
    private func errorMessage(for assetType: AssetType) -> String? {
        switch assetType {
        case .ethereum: return LocalizationConstants.SendEther.waitingForPaymentToFinishMessage
        default: return nil
        }
    }
}

extension ExchangeRates {
    func exchangeRateDescription(fromCurrency: String, toCurrency: String) -> String {
        guard let rate = pairRate(fromCurrency: fromCurrency, toCurrency: toCurrency) else {
            return ""
        }
        return "1 \(fromCurrency) = \(rate.price) \(toCurrency)"
    }
}
