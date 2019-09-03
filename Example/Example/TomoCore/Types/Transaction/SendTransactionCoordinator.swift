//
//  SendTransactionCoordinator.swift
//  Example
//
//  Created by Admin on 9/3/19.
//  Copyright © 2019 Admin. All rights reserved.
//

import Foundation
import Result
import BigInt

enum ConfirmType {
    case sign
    case signThenSend
}

enum ConfirmResult {
    case signedTransaction(SentTransaction)
    case sentTransaction(SentTransaction)
}

final class SendTransactionCoordinator{
    private let keystore: TomoKeystore
    let server: RPCServer
    let provider = ApiProviderFactory.makeRPCNetworkProvider()
    
    init(keystore: TomoKeystore,server: RPCServer) {
        self.keystore = keystore
        self.server = server
    }
    
    
    private func send(confirmType: ConfirmType, transaction: SignTransaction,completion: @escaping (Result<ConfirmResult, AnyError>) -> Void) {
        if transaction.nonce >= 0 {
            signAndSend(confirmType: confirmType, transaction: transaction, completion: completion)
        } else {
            provider.request(.getTransactionCount(server: server, address: transaction.account.address.description)) { (result) in
                switch result{
                case .success(let response):
                    guard let responseValue:[String: Any] = (try! response.mapJSON() as? [String: Any]),let countHash = responseValue["result"] as? String, let count = BigInt(countHash.drop0x, radix: 16) else{
                        return
                    }
                    let transaction = self.appendNonce(to: transaction, currentNonce: count)
                    self.signAndSend(confirmType: confirmType, transaction: transaction, completion: completion)
                case .failure(let error):
                    completion(.failure(AnyError(error)))
                }
            }
        }
    }
    private func appendNonce(to: SignTransaction, currentNonce: BigInt) -> SignTransaction {
        return SignTransaction(
            value: to.value,
            account: to.account,
            to: to.to,
            nonce: currentNonce,
            data: to.data,
            gasPrice: to.gasPrice,
            gasLimit: to.gasLimit,
            chainID: to.chainID
            
        )
    }
    
    private func signAndSend(confirmType: ConfirmType, transaction: SignTransaction,completion: @escaping (Result<ConfirmResult, AnyError>) -> Void) {
        let signedTransaction = keystore.signTransaction(transaction)
        switch signedTransaction {
        case .success(let data):
            approve(confirmType: confirmType, transaction: transaction, data: data, completion: completion)
        case .failure(let error):
            completion(.failure(AnyError(error)))
        }
    }
    
    private func approve(confirmType: ConfirmType, transaction: SignTransaction, data: Data, completion: @escaping (Result<ConfirmResult, AnyError>) -> Void) {
        let id = data.sha3(.keccak256).hexEncoded
        let sentTransaction = SentTransaction(
            id: id,
            original: transaction,
            data: data
        )
        let dataHex = data.hexEncoded
        switch confirmType {
        case .sign:
            completion(.success(.signedTransaction(sentTransaction)))
        case .signThenSend:
            provider.request(.sendRawTransaction(server: server, signedTransaction: dataHex)) { (result) in
                switch result {
                case .success(let result):
                    do{
                        let jsonrpcRespone = try JSONDecoder().decode(JsonrpcRespone.self, from: result.data)
                        
                        if jsonrpcRespone.error == nil{
                            completion(.success(.sentTransaction(sentTransaction)))
                        }else{
                            let error =  NSError(domain: jsonrpcRespone.error!.message, code: jsonrpcRespone.error!.code, userInfo: nil) as Error
                            completion(.failure(AnyError(error)))
                        }
                    }catch{
                        completion(.failure(AnyError(error)))
                    }
                case .failure(let error):
                    completion(.failure(AnyError(error)))
                }
            }
            
        }
    }

}

struct JsonrpcRespone: Decodable {
    let jsonrpc: String
    let id: Int
    var result: String?
    var error: RPCError?
    
    private enum JsonrpcResponeObjectKeys: String, CodingKey {
        case error
        case jsonrpc
        case id
        case result
    }
    
    init(from decoder: Decoder) throws {
        let containers = try decoder.container(keyedBy: JsonrpcResponeObjectKeys.self)
        self.jsonrpc = try containers.decodeIfPresent(String.self, forKey: .jsonrpc) ?? ""
        self.id = try containers.decodeIfPresent(Int.self, forKey: .id) ?? 0
        self.result = try containers.decodeIfPresent(String.self, forKey: .result)
        self.error = try containers.decodeIfPresent(RPCError.self, forKey: .error)
        
    }
}
struct RPCError: Decodable {
    let message: String
    let code: Int
}

