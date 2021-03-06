//
//  DeepLinkHandler.swift
//  Blockchain
//
//  Created by Chris Arriola on 10/29/18.
//  Copyright © 2018 Blockchain Luxembourg S.A. All rights reserved.
//

import Firebase

class DeepLinkHandler {

    private let appSettings: BlockchainSettings.App

    init(appSettings: BlockchainSettings.App = BlockchainSettings.App.shared) {
        self.appSettings = appSettings
    }

    func handle(deepLink: URL) {
        Logger.shared.debug("Attempting to handle deep link \(deepLink.absoluteString)")
        guard let route = DeepLinkRoute.route(from: deepLink),
            let payload = DeepLinkPayload.create(from: deepLink) else {
            return
        }

        switch route {
        case .xlmAirdop:
            handleXlmAirdrop(payload.params)
        }
    }

    private func handleXlmAirdrop(_ params: [String: String]) {
        appSettings.didTapOnAirdropDeepLink = true
        appSettings.didAttemptToRouteForAirdrop = false
        appSettings.airdropCampaignCode = params["campaign_code"]
        appSettings.airdropCampaignEmail = params["campaign_email"]
        Analytics.setUserProperty(AnalyticsService.Campaigns.sunriver.rawValue, forName: "campaign")
    }
}
