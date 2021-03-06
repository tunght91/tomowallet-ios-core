//
//  TransactionConfiguration.swift
//  Example
//
//  Created by Admin on 9/5/19.
//  Copyright © 2019 Admin. All rights reserved.
//

import Foundation
import BigInt
import PromiseKit

public struct PreviewTransaction {
    let value: BigInt
    let account: Account
    let address: EthereumAddress?
    let contract: EthereumAddress?
    let nonce: BigInt
    let data: Data
    let gasPrice: BigInt
    let gasLimit: BigInt
    let transfer: Transfer
}

final class TransactionConfigurator {
    let account: Account
    let tomoBalance: BigInt
    let transaction: UnconfirmedTransaction
    let server: RPCServer
    let chainState: ChainSate
    let networkProvider : NetworkProviderProtocol
    var configuration: TransactionConfiguration {
        didSet {
            configurationUpdate.value = configuration
        }
    }
    var configurationUpdate: Subscribable<TransactionConfiguration> = Subscribable(nil)
    
    init(
        account: Account,
        tomoBalance: BigInt,
        transaction: UnconfirmedTransaction,
        chainState: ChainSate,
        networkProvider: NetworkProviderProtocol,
        server: RPCServer) {
    
        self.account = account
        self.transaction = transaction
        self.server = server
        self.chainState = chainState
        self.networkProvider = networkProvider
        self.tomoBalance = tomoBalance
        let data: Data = TransactionConfigurator.data(for: transaction, from: account.address)
        let calculatedGasLimit = transaction.gasLimit ?? TransactionConfigurator.gasLimit(for: transaction.transfer.type)
        let calculatedGasPrice = transaction.gasPrice ?? max(chainState.gasPrice ?? BigInt(0), GasPriceConfiguration.default)
        self.configuration = TransactionConfiguration(
            gasPrice: calculatedGasPrice,
            gasLimit: calculatedGasLimit,
            tokenFee: .none,
            data: data,
            nonce: transaction.nonce
        )
    }
    
    func load(completion: @escaping (_ balanceStatus: BalanceStatus) -> Void) {
        switch transaction.transfer.type {
        case .tomo:
            self.checkBalanceStatusGasFeeByTomo(completion: completion)
        case .token(let token, _ ):
            switch token.type{
            case .TRC21(let isApplyTomoZ):
                if isApplyTomoZ{
                    checkBalanceStatusGasFeeByToken(token: token, completion: completion)
                    
                }else{
                    self.checkBalanceStatusGasFeeByTomo(completion: completion)
                }
            default:
                self.checkBalanceStatusGasFeeByTomo(completion: completion)
            }
        }
    }
    
    private func checkBalanceStatusGasFeeByTomo(completion: @escaping (_ balanceStatus: BalanceStatus) -> Void) {
        firstly {
            self.estimateGasLimit()
            }.done { gasLimit in
                self.refreshGasLimit(gasLimit)
                completion(self.balanceValidStatus())
            }.catch { (_) in
                completion(self.balanceValidStatus())
        }
    }
    private func checkBalanceStatusGasFeeByToken(token: TRCToken ,completion: @escaping (_ balanceStatus: BalanceStatus) -> Void) {
        firstly {
            networkProvider.estimateFeeTRC21(contract: token.contract.description, amount: transaction.value)
            }.done { gasFee in
                self.refreshTokenfee(gasFee)
                completion(self.balanceValidStatus())
            }.catch { (_) in
                completion(self.balanceValidStatus())
        }
    }
    
    
    private static func data(for transaction: UnconfirmedTransaction, from: Address) -> Data {
        guard let to = transaction.to else { return Data() }
        switch transaction.transfer.type {
        case .tomo:
            return transaction.data ?? Data()
        case .token:
            return ERC20Encoder.encodeTransfer(to: to, tokens: transaction.value.magnitude)
        }
    }
    
    private static func gasLimit(for type: TransferType) -> BigInt {
        switch type {
        case .tomo:
            return GasLimitConfiguration.default
        case .token:
            return GasLimitConfiguration.tokenTransfer
        }
    }


    func estimateGasLimit() -> Promise<BigInt> {
        return networkProvider.getEstimateGasLimit(tx: self.signTransaction)
    }
    func estimateGasPrice() -> BigInt {
        return chainState.gasPrice ?? GasPriceConfiguration.default
    }
    
    // combine into one function
    
    func refreshGasLimit(_ gasLimit: BigInt) {
        configuration = TransactionConfiguration(
            gasPrice: configuration.gasPrice,
            gasLimit: gasLimit,
            tokenFee: configuration.tokenFee,
            data: configuration.data,
            nonce: configuration.nonce
        )
    }
    // combine into one function
    
    func refreshTokenfee(_ fee: BigInt) {
        configuration = TransactionConfiguration(
            gasPrice: configuration.gasPrice,
            gasLimit: configuration.gasLimit,
            tokenFee: fee,
            data: configuration.data,
            nonce: configuration.nonce
        )
    }
    
    func valueToSend() -> BigInt {
        return transaction.value
    }
    
    func previewTransaction() -> PreviewTransaction {
        return PreviewTransaction(
            value: valueToSend(),
            account: account,
            address: transaction.to,
            contract: .none,
            nonce: configuration.nonce,
            data: configuration.data,
            gasPrice: configuration.gasPrice,
            gasLimit: configuration.gasLimit,
            transfer: transaction.transfer
        )
    }
    
    var signTransaction: SignTransaction {
        let value: BigInt = {
            switch transaction.transfer.type {
            case .tomo: return valueToSend()
            case .token: return 0
            }
        }()
        let address: EthereumAddress? = {
            switch transaction.transfer.type {
            case .tomo: return transaction.to
            case .token(let token,_): return token.contract
            }
        }()
      
        let signTransaction = SignTransaction(
            tranfer: transaction.transfer,
            value: value,
            from: EthereumAddress(string: account.address.description)!,
            to: address,
            nonce: configuration.nonce,
            data: configuration.data,
            gasPrice: configuration.gasPrice,
            gasLimit: configuration.gasLimit,
            gasFeeByTRC21: configuration.tokenFee,
            chainID: server.chainID
        )
        
        return signTransaction
    }
    
    func update(configuration: TransactionConfiguration) {
        self.configuration = configuration
    }
    
    func balanceValidStatus() -> BalanceStatus {
        var tomoSufficient = true
        var gasSufficient = true
        var tokenSufficient = true

        let transaction = previewTransaction()
        let totalGasValue = transaction.gasPrice * transaction.gasLimit

        //We check if it is Tomo or token operation.
        switch transaction.transfer.type {
        case .tomo:
            if transaction.value > tomoBalance {
                tomoSufficient = false
                gasSufficient = false
            } else {
                if totalGasValue + transaction.value > tomoBalance {
                    gasSufficient = false
                }
            }
            return .tomo(tomoSufficient: tomoSufficient, gasSufficient: gasSufficient)
        case .token(let token, let tokenBalance):
            switch token.type{
            case .TRC21(let isApplyIssuer):
                if isApplyIssuer{
                 
                    if transaction.value > tokenBalance {
                        tokenSufficient = false
                    }
                    if self.configuration.tokenFee ?? BigInt(0) > tokenBalance {
                        tomoSufficient = false
                        gasSufficient = false
                    }
                    return .token(tokenSufficient: tokenSufficient, gasSufficient: gasSufficient)
                    
                    
                }else{
                    if totalGasValue > tomoBalance {
                        tomoSufficient = false
                        gasSufficient = false
                    }
                    if transaction.value > tokenBalance {
                        tokenSufficient = false
                    }
                    return .token(tokenSufficient: tokenSufficient, gasSufficient: gasSufficient)
                }
            default:
                if totalGasValue > tomoBalance {
                    tomoSufficient = false
                    gasSufficient = false
                }
                if transaction.value > tokenBalance {
                    tokenSufficient = false
                }
                return .token(tokenSufficient: tokenSufficient, gasSufficient: gasSufficient)
                
            }
            
        }
    }
}

