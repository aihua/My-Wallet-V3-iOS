//
//  ExchangeCoordinator.swift
//  Blockchain
//
//  Created by kevinwu on 7/26/18.
//  Copyright © 2018 Blockchain Luxembourg S.A. All rights reserved.
//

import Foundation
import RxSwift
import StellarKit

protocol ExchangeDependencies {
    var service: ExchangeHistoryAPI { get }
    var markets: ExchangeMarketsAPI { get }
    var conversions: ExchangeConversionAPI { get }
    var inputs: ExchangeInputsAPI { get }
    var tradeExecution: TradeExecutionAPI { get }
    var assetAccountRepository: AssetAccountRepository { get }
    var tradeLimits: TradeLimitsAPI { get }
}

struct ExchangeServices: ExchangeDependencies {
    let service: ExchangeHistoryAPI
    let markets: ExchangeMarketsAPI
    var conversions: ExchangeConversionAPI
    let inputs: ExchangeInputsAPI
    let tradeExecution: TradeExecutionAPI
    let assetAccountRepository: AssetAccountRepository
    let tradeLimits: TradeLimitsAPI

    init() {
        service = ExchangeService()
        markets = MarketsService()
        conversions = ExchangeConversionService()
        inputs = ExchangeInputsService()
        assetAccountRepository = AssetAccountRepository.shared
        tradeExecution = TradeExecutionService(dependencies: TradeExecutionService.Dependencies())
        tradeLimits = TradeLimitsService()
    }
}

@objc class ExchangeCoordinator: NSObject, Coordinator {

    private enum ExchangeType {
        case homebrew
        case shapeshift
    }

    static let shared = ExchangeCoordinator()

    // class function declared so that the ExchangeCoordinator singleton can be accessed from obj-C
    @objc class func sharedInstance() -> ExchangeCoordinator {
        return ExchangeCoordinator.shared
    }
    
    // MARK: Public Properties
    
    weak var exchangeOutput: ExchangeListOutput?

    private let walletManager: WalletManager

    private let walletService: WalletService

    private var disposable: Disposable?
    
    private var exchangeListViewController: ExchangeListViewController?
    private var limitsService: TradeLimitsAPI = {
        return ExchangeServices().tradeLimits
    }()

    // MARK: - Navigation
    private var navigationController: ExchangeNavigationController?
    private var exchangeViewController: PartnerExchangeListViewController?
    private var rootViewController: UIViewController?

    // MARK: - Entry Point

    func start() {
        let user = BlockchainDataRepository.shared.nabuUser
            .take(1)
            .asSingle()
        let tiers = BlockchainDataRepository.shared.tiers
            .take(1)
            .asSingle()
        disposable = Single.zip(user, tiers)
            .subscribeOn(MainScheduler.asyncInstance)
            .observeOn(MainScheduler.instance)
            .subscribe(onSuccess: { [weak self] payload in
                guard let strongSelf = self else { return }
                let user = payload.0
                let tiersResponse = payload.1

                let approved = tiersResponse.userTiers.contains(where: {
                    return $0.tier != .tier0 && $0.state == .verified
                })
                guard approved == true else {
                    strongSelf.routeToTiers()
                    return
                }
                
                strongSelf.showAppropriateExchange()
                Logger.shared.debug("Got user with ID: \(user.personalDetails?.identifier ?? "")")
            }, onError: { [weak self] error in
                guard let strongSelf = self else { return }
                AlertViewPresenter.shared.standardError(
                    message: strongSelf.errorMessage(for: error),
                    title: LocalizationConstants.Errors.error,
                    in: strongSelf.rootViewController
                )
                Logger.shared.error("Failed to get user: \(error.localizedDescription)")
            })
    }
    
    private func routeToTiers() {
        guard let viewController = rootViewController else {
            Logger.shared.error("View controller to present on is nil")
            return
        }
        disposable = KYCTiersViewController.routeToTiers(
            fromViewController: viewController
        )
    }

    // TICKET: IOS-1168 - Complete error handling TODOs throughout the KYC
    private func errorMessage(for error: Error) -> String {
        guard let serverError = error as? HTTPRequestServerError,
            case let .badStatusCode(_, badStatusCodeError) = serverError,
            let nabuError = badStatusCodeError as? NabuNetworkError else {
                return error.localizedDescription
        }
        switch (nabuError.type, nabuError.code) {
        case (.conflict, .userRegisteredAlready):
            return LocalizationConstants.KYC.emailAddressAlreadyInUse
        default:
            return error.localizedDescription
        }
    }

    private func showAppropriateExchange() {
        initXlmAccountIfNeeded { [unowned self] in
            if !self.walletManager.wallet.hasEthAccount() {
                self.createEthAccountForExchange()
            } else {
                self.showExchange(type: .homebrew)
            }
        }
    }

    private func initXlmAccountIfNeeded(completion: @escaping (() -> ())) {
        disposable = xlmAccountRepository.initializeMetadataMaybe()
            .flatMap({ [unowned self] _ in
                return self.stellarAccountService.currentStellarAccount(fromCache: true)
            })
            .subscribeOn(MainScheduler.asyncInstance)
            .observeOn(MainScheduler.instance)
            .subscribe(onSuccess: { _ in
                completion()
            }, onError: { error in
                Logger.shared.error("Failed to fetch XLM account.")
            })
    }

    private func createEthAccountForExchange() {
        if walletManager.wallet.needsSecondPassword() {
            AuthenticationCoordinator.shared.showPasswordConfirm(
                withDisplayText: LocalizationConstants.Authentication.etherSecondPasswordPrompt,
                headerText: LocalizationConstants.Authentication.secondPasswordRequired,
                validateSecondPassword: true,
                confirmHandler: { (secondPassword) in
                    self.walletManager.wallet.createEthAccount(forExchange: secondPassword)
            }
            )
        } else {
            walletManager.wallet.createEthAccount(forExchange: nil)
        }
    }

    private func showExchange(type: ExchangeType, country: KYCCountry? = nil) {
        switch type {
        case .homebrew:
            guard let viewController = rootViewController else {
                Logger.shared.error("View controller to present on is nil")
                return
            }
            let listViewController = ExchangeListViewController.make(with: ExchangeServices(), coordinator: self)
            navigationController = ExchangeNavigationController(
                rootViewController: listViewController,
                title: LocalizationConstants.Swap.swap
            )
            viewController.present(navigationController!, animated: true)
        case .shapeshift:
            guard let viewController = rootViewController else {
                Logger.shared.error("View controller to present on is nil")
                return
            }
            exchangeViewController = PartnerExchangeListViewController.create(withCountryCode: country?.code)
            let partnerNavigationController = ExchangeNavigationController(
                rootViewController: exchangeViewController,
                title: LocalizationConstants.Swap.swap
            )
            viewController.present(partnerNavigationController, animated: true)
        }
    }

    private func showCreateExchange(animated: Bool, type: ExchangeType, country: KYCCountry? = nil) {
        switch type {
        case .homebrew:
            let exchangeCreateViewController = ExchangeCreateViewController.make(with: ExchangeServices())
            if navigationController == nil {
                guard let viewController = rootViewController else {
                    Logger.shared.error("View controller to present on is nil")
                    return
                }
                navigationController = ExchangeNavigationController(
                    rootViewController: exchangeCreateViewController,
                    title: LocalizationConstants.Exchange.navigationTitle
                )
                viewController.topMostViewController?.present(navigationController!, animated: animated)
            } else {
                navigationController?.pushViewController(exchangeCreateViewController, animated: animated)
            }
        case .shapeshift:
            showExchange(type: .shapeshift, country: country)
        }
    }

    private func showConfirmExchange(orderTransaction: OrderTransaction, conversion: Conversion) {
        guard let navigationController = navigationController else {
            Logger.shared.error("No navigation controller found")
            return
        }
        let model = ExchangeDetailViewController.PageModel.confirm(orderTransaction, conversion)
        let confirmController = ExchangeDetailViewController.make(with: model, dependencies: ExchangeServices())
        navigationController.pushViewController(confirmController, animated: true)
    }
    
    private func showLockedExchange(orderTransaction: OrderTransaction, conversion: Conversion) {
        guard let navigationController = navigationController else {
            Logger.shared.error("No navigation controller found")
            return
        }
        let model = ExchangeDetailViewController.PageModel.locked(orderTransaction, conversion)
        let controller = ExchangeDetailViewController.make(with: model, dependencies: ExchangeServices())
        navigationController.present(controller, animated: true, completion: nil)
    }

    private func showTradeDetails(trade: ExchangeTradeModel) {
        let detailViewController = ExchangeDetailViewController.make(with: .overview(trade), dependencies: ExchangeServices())
        navigationController?.pushViewController(detailViewController, animated: true)
    }

    // MARK: - Event handling
    enum ExchangeCoordinatorEvent {
        case createHomebrewExchange(animated: Bool, viewController: UIViewController?)
        case createPartnerExchange(country: KYCCountry, animated: Bool)
        case confirmExchange(orderTransaction: OrderTransaction, conversion: Conversion)
        case sentTransaction(orderTransaction: OrderTransaction, conversion: Conversion)
        case showTradeDetails(trade: ExchangeTradeModel)
    }

    func handle(event: ExchangeCoordinatorEvent) {
        switch event {
        case .createHomebrewExchange(let animated, let viewController):
            if viewController != nil {
                rootViewController = viewController
            }
            showCreateExchange(animated: animated, type: .homebrew)
        case .createPartnerExchange(let country, let animated):
            showCreateExchange(animated: animated, type: .shapeshift, country: country)
        case .confirmExchange(let orderTransaction, let conversion):
            showConfirmExchange(orderTransaction: orderTransaction, conversion: conversion)
        case .sentTransaction(orderTransaction: let transaction, conversion: let conversion):
            showLockedExchange(orderTransaction: transaction, conversion: conversion)
        case .showTradeDetails(let trade):
            showTradeDetails(trade: trade)
        }
    }

    // MARK: - Services
    private let marketsService: MarketsService
    private let exchangeService: ExchangeService
    private let stellarAccountService: StellarAccountAPI
    private let xlmAccountRepository: StellarWalletAccountRepository

    // MARK: - Lifecycle
    private init(
        walletManager: WalletManager = WalletManager.shared,
        walletService: WalletService = WalletService.shared,
        marketsService: MarketsService = MarketsService(),
        exchangeService: ExchangeService = ExchangeService(),
        stellarAccountService: StellarAccountAPI = XLMServiceProvider.shared.services.accounts,
        xlmAccountRepository: StellarWalletAccountRepository = XLMServiceProvider.shared.services.repository
    ) {
        self.walletManager = walletManager
        self.walletService = walletService
        self.marketsService = marketsService 
        self.exchangeService = exchangeService
        self.stellarAccountService = stellarAccountService
        self.xlmAccountRepository = xlmAccountRepository
        super.init()
    }

    deinit {
        disposable?.dispose()
        disposable = nil
    }
}

// MARK: - Coordination
@objc extension ExchangeCoordinator {
    func start(rootViewController: UIViewController) {
        self.rootViewController = rootViewController
        start()
    }

    func reloadSymbols() {
        exchangeViewController?.reloadSymbols()
    }
}

extension ExchangeCoordinator {
    func subscribeToRates() {

    }
}
