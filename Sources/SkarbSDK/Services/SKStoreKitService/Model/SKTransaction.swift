//
//  SKTransaction.swift
//  SkarbSDK
//
//  Created by Siarhei Karotki on 01/04/2025.
//

import StoreKit

struct SKTransaction: Codable, Hashable {
  let transactionId: String
  let productId: String
  let jwtRepresentation: String
}
