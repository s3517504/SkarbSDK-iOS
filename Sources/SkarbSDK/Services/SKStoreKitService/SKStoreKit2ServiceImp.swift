// //
////  SKStoreKit2ServiceImp.swift
////  SkarbSDK
////
////  Created by Siarhei Karotki on 31/03/2025.
////
//
import Foundation
import StoreKit

final class SKStoreKit2ServiceImp: NSObject, SKStoreKitService {
  //  MARK: - Public (Properties)
  weak var delegate: SKStoreKitDelegate?
  
  var allProducts: [Product]? {
    var localAllProducts: [Product]? = nil
    exclusionSerialQueue.sync {
      localAllProducts = cachedAllProducts
    }
    
    return localAllProducts
  }
  
  var canMakePayments: Bool {
    return AppStore.canMakePayments
  }
  
  
  //  MARK: - Private (Properties)
  private let exclusionSerialQueue = DispatchQueue(label: "com.skarbSDK.skStoreKitService.exclusion")
  private var cachedAllProducts: [Product] = []
  private var purchasingProductCompletions: [String: ((Result<Bool, Error>) -> Void)] = [:]

  //  MARK: - Initializer
  override init() {
    super.init()
    SKPaymentQueue.default().add(self) // StoreKit 1 (for promoted purchases)
    subscribeOnTransactionUpdates()
  }
  
//  MARK: - Public (Interface)
  func requestProductInfoAndSendPurchase(command: SKCommand) {
    var editedCommand = command
    guard let fetchProducts = try? JSONDecoder().decode(Array<SKFetchProduct>.self, from: command.data) else {
      // Logging
      let dataString = String(describing: String(data: command.data, encoding: .utf8))
      SKLogger.logPurchase("Command data decoding error. Command.data == \(dataString)")
      
      let feautures = [
        SKLoggerFeatureType.internalError.name: SKLoggerFeatureType.internalError.name
      ]
      SKLogger.logError(
        "SKSyncServiceImplementation requestProductInfoAndSendPurchase: called with fetchProducts but command.data is not SKFetchProduct. Command.data == \(dataString)",
        features: feautures
      )
      // end Logging

      editedCommand.changeStatus(to: .canceled)
      SKServiceRegistry.commandStore.saveCommand(editedCommand)
      return
    }
    
    let productIds = fetchProducts.map({ $0.productId })
    // Logging
    SKLogger.logPurchase("Command product ids: \(productIds)")
    // end Logging
    
    requestProductsInfo(productIds: productIds) { [weak self] result in
      switch result {
      case .success(let products):
        if !products.isEmpty {
          editedCommand.changeStatus(to: .done)
        } else {
          editedCommand.updateRetryCountAndFireDate()
          editedCommand.changeStatus(to: .pending)
        }
        SKServiceRegistry.commandStore.saveCommand(editedCommand)
        self?.createPriceCommand(fetchProducts: fetchProducts,
                                 products: products,
                                 command: editedCommand,
                                 regionCode: "",
                                 countryCode: "")
      case .failure(let error):
        // Logging
        SKLogger.logPurchase("Method 'requestProductInfoAndSendPurchase' did finish with error: \(error)")
        SKLogger.logError(
          "Method 'requestProductInfoAndSendPurchase' did finish with error: \(error)",
          features: [
            SKLoggerFeatureType.purchase.name: SKLoggerFeatureType.purchase.name
          ]
        )
        // end Logging
      }
    }
  }
  
  func restorePurchases(completion: @escaping (Result<Bool, Error>) -> Void) {
    SKLogger.logPurchase(#function)

    Task { @MainActor in
      dispatchPrecondition(condition: .onQueue(.main))
      do {
        // Logging
        SKLogger.logPurchase("Restore did start and waiting for AppStore.sync()")
        // end Logging
        
        try await AppStore.sync()
        
        // Logging
        SKLogger.logPurchase("Start checking transactions ...")
        var currentTransactions: [String] = []
        // end Logging

        var activeVerificationResults: [VerificationResult<Transaction>] = []
        
        for await verificationResult in Transaction.all {
          guard case .verified(let transaction) = verificationResult else { continue }
          
          /// check only active transactions
          if transaction.revocationDate == nil {
            
            // Logging
            SKLogger.logPurchase("Handling current transaction with id: \(transaction.id), for productId: \(transaction.productID)")
            currentTransactions.append(transaction.id.description)
            // end Logging

            activeVerificationResults.append(verificationResult)
            storeTransaction(with: verificationResult)
          }
        }
        await handlePurchased(activeVerificationResults)
        completion(.success(true))
        
        // Logging
        SKLogger.logPurchase("Restore did finish with handled transactions: \(currentTransactions)")
        // end Logging
      } catch let error {
        completion(.failure(error))
        
        // Logging
        SKLogger.logPurchase("Restore did finish with error: \(error.localizedDescription)")
        // end Logging
      }
    }
  }
  
  func purchasePackage(_ package: SKOfferPackage, completion: @escaping (Result<Bool, Error>) -> Void) {
    let product = package.storeProduct
    // Logging
    SKLogger.logPurchase("Purchase initiated with productId = \(product.id)")
    // end Logging
    
    Task { @MainActor in
      dispatchPrecondition(condition: .onQueue(.main))
      do {
        let purchaseResult = try await product.purchase()
        delegate?.storeKitUpdatedTransaction(purchaseResult)
        
        switch purchaseResult {
        case .success(let verificationResult):
          await handlePurchased([verificationResult], completion: completion)
        case .userCancelled:
          completion(.failure(SKError(.paymentCancelled)))
        case .pending:
//          completion(.failure(SKError(.p)))
          break
        @unknown default:
          completion(.failure(SKError(.unknown)))
        }
      } catch let error {
        completion(.failure(error))
      }
    }
  }
  
  /// Might be called on any thread. Callback wil be on the main thread
  func requestProductsInfo(productIds: [String],
                           completion: @escaping (Result<[Product], Error>) -> Void) {
    // Logging
    SKLogger.logPurchase(#function)
    // end Logging

    Task { @MainActor in
      dispatchPrecondition(condition: .onQueue(.main))
      do {
        // Logging
        SKLogger.logPurchase("Fetching products did start with productsIds: \(productIds)")
        // end Logging
        
        let products = try await Product.products(for: productIds)
        chacheProductsIfNeeded(products)
        
        // Logging
        SKLogger.logPurchase("Fetching products did finsih.")
        // end Logging

        completion(.success(allProducts ?? []))
      } catch {
        // Logging
        SKLogger.logPurchase("Fetching products did finish with error: \(error.localizedDescription)")
        // end Logging
        
        completion(.failure(error))
      }
    }
  }
  
  func fetchProduct(by productId: String) -> Product? {
    return allProducts?.filter({ $0.id == productId }).first
  }
}

//MARK: - SKPaymentTransactionObserver
extension SKStoreKit2ServiceImp: SKPaymentTransactionObserver {
  /// Sent when the transaction array has changed (additions or state changes).  Client should check state of transactions and finish as appropriate.
  public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) { }
  public func paymentQueue(_ queue: SKPaymentQueue,
                           shouldAddStorePayment payment: SKPayment,
                           for product: SKProduct) -> Bool {
    return delegate?.storeKit(shouldAddStorePayment: payment, for: product) ?? false
  }
}

//MARK: - Private
private extension SKStoreKit2ServiceImp {
  private func subscribeOnTransactionUpdates() {
    Task.detached { [weak self] in
      guard let self = self else { return }
      
      for await result in Transaction.updates {
        if case .verified(let transaction) = result {
          // Logging
          SKLogger.logPurchase("Transaction.updates called with id: \(transaction.id), productId: \(transaction.productID)")
          // end Logging
          
          await handlePurchased([result], completion: nil)
        }
      }
    }
  }
  
  /// save transaction to store in order to fetch them for verification
  private func storeTransaction(with verificationResult: VerificationResult<Transaction>) {
    exclusionSerialQueue.sync {
      switch verificationResult {
      case .verified(let transaction):
        let skTransaction = SKTransaction(
          transactionId: transaction.id.description,
          productId: transaction.productID,
          jwtRepresentation: verificationResult.jwsRepresentation
        )
        SKServiceRegistry.userDefaultsService.insertItemToCodableSet(forKey: .transactions, item: skTransaction)

        // Logging
        SKLogger.logPurchase("Transaction did cache with id: \(skTransaction.transactionId), productId: \(skTransaction.productId)")
        // end Logging
        
      case .unverified:
        break
      }
    }
  }
  
  private func chacheProductsIfNeeded(_ products: [Product]) {
    exclusionSerialQueue.sync {
      products.forEach { product in
        let isNotCachedProduct = cachedAllProducts.filter({ $0.id == product.id }).first == nil
        if isNotCachedProduct {
          cachedAllProducts.append(product)
        }
      }
      // Logging
      SKLogger.logPurchase("Products did chache.")
      // end Logging
    }
  }
  
  private func handlePurchased(_ verificationResults: [VerificationResult<Transaction>], completion: ((Result<Bool, Error>) -> Void)? = nil) async {
    var transactions: [Transaction] = []
    
    for verificationResult in verificationResults {
      switch verificationResult {
      case .unverified(_, let verificationError):
        DispatchQueue.main.async {
          completion?(.failure(verificationError))
        }
        
      case .verified(let transaction):
        await transaction.finish()
        transactions.append(transaction)
        if #available(iOS 16.0, *) {
            do {
                let appTransaction = try await AppTransaction.shared
              let jws = appTransaction.jwsRepresentation
                    print(jws)
                
            } catch {
                print("Ошибка при получении AppTransaction: \(error)")
            }
        }
        storeTransaction(with: verificationResult)

        DispatchQueue.main.async {
          completion?(.success(true))
        }
        // Logging
        SKLogger.logPurchase("Purchased [SUCCESS] with transactionId = \(transaction.id), transactionDate = \(String(describing: transaction.originalPurchaseDate)), product: \(transaction.productID)")
        // end Logging
      }
    }
    createFetchProductsCommand(purchasedTransactions: transactions)
    await createPurchaseAndTransactionCommand(transaction: transactions)
  }
}

//MARK: - Commands
private extension SKStoreKit2ServiceImp {
  /// Create one SKFetchProduct or each unique productId.
  /// Need to attach the newest transaction Date and Id
  func createFetchProductsCommand(purchasedTransactions: [Transaction]) {
    // Logging
    SKLogger.logPurchase("[SKCommand] createFetchProductsCommand did call with tranasctions: \(purchasedTransactions.map({ $0.id.description })), products: \(purchasedTransactions.map({ $0.productID }))")
    // end Logging
    
    let productIds = Array(Set(purchasedTransactions.map { $0.productID.description }))
    
    var fetchProducts: [SKFetchProduct] = []
    for productId in productIds {
      let transaction = purchasedTransactions
        .filter { $0.productID.description == productId }
        .sorted { $0.purchaseDate < $1.purchaseDate }
        .last
      if let transaction = transaction {
        fetchProducts.append(SKFetchProduct(productId: transaction.productID.description,
                                            transactionDate: transaction.purchaseDate,
                                            transactionId: transaction.id.description))
      }
    }
    
    if let productData = try? JSONEncoder().encode(fetchProducts) {
      let fetchCommand = SKCommand(
        commandType: .fetchProducts,
        status: .pending,
        data: productData
      )
      SKServiceRegistry.commandStore.saveCommand(fetchCommand)
      // Logging
      SKLogger.logPurchase("[SKCommand] createFetchProductsCommand did finish with.")
      // end Logging
    } else {
      // Logging
      let features = [
        SKLoggerFeatureType.internalError.name: SKLoggerFeatureType.internalError.name,
        SKLoggerFeatureType.internalValue.name: fetchProducts.description
      ]
      SKLogger.logError(
        "createFetchProductsCommand did finish with error try? JSONEncoder().encode(fetchProducts) == nil",
        features: features
      )
      SKLogger.logPurchase("[SKCommand] createFetchProductsCommand did finish with error try? JSONEncoder().encode(fetchProducts) == nil")
      // end Logging
    }
  }
  
  func createPriceCommand(fetchProducts: [SKFetchProduct],
                          products: [Product],
                          command: SKCommand,
                          regionCode: String,
                          countryCode: String) {
    // Logging
    SKLogger.logPurchase("[SKCommand] createPriceCommand did start for products: \(products.map({ $0.id }))")
    // end Logging
    
    var priceApiProducts: [Priceapi_Product] = []
    
    fetchProducts.forEach { fetchProduct in
      guard
        let product = products.first(where: { $0.id == fetchProduct.productId })
      else {
        // Logging
        let features: [String: Any] = [
          SKLoggerFeatureType.internalError.name: SKLoggerFeatureType.internalError.name,
          SKLoggerFeatureType.retryCount.name: command.retryCount
        ]
        SKLogger.logError(
          "SKSyncServiceImplementation. Send command for price. Product is nil. FetchProduct = \(fetchProduct.productId)",
          features: features
        )
        SKLogger.logPurchase("[SKCommand] createPriceCommand did finish with error for products: \(products.map({ $0.id }))")
        // end Logging
        return
      }
      
      let priceApiProduct = Priceapi_Product(
        product: product,
        transactionDate: fetchProduct.transactionDate,
        transactionId: fetchProduct.transactionId
      )
      priceApiProducts.append(priceApiProduct)
    }
    
    guard !priceApiProducts.isEmpty else { return }
    let productRequest = Priceapi_PricesRequest(
      storefront: countryCode,
      region: regionCode,
      currency: products.first?.priceFormatStyle.currencyCode,
      products: priceApiProducts
    )
    let command = SKCommand(
      commandType: .priceV4,
      status: .pending,
      data: productRequest.getData()
    )
    SKServiceRegistry.commandStore.saveCommand(command)
    // Logging
    SKLogger.logPurchase("[SKCommand] createPriceCommand did finish for products: \(products.map({ $0.id }))")
    // end Logging
  }
  
  func createPurchaseAndTransactionCommand(transaction: [Transaction]) async {
    let transactionIds: [String] = transaction.compactMap { $0.id.description }
    let countryCode: String? = await Storefront.current?.countryCode
    
    let installData = SKServiceRegistry.commandStore.getDeviceRequest()
    if !SKServiceRegistry.commandStore.hasPurhcaseV4Command {
      let purchaseDataV4 = Purchaseapi_ReceiptRequest(
        storefront: countryCode,
        region: await Storefront.current?.countryCode,
        currency: allProducts?.first?.priceFormatStyle.currencyCode,
        newTransactions: transactionIds,
        docFolderDate: installData?.docDate,
        appBuildDate: installData?.buildDate
      )
      let purchaseV4Command = SKCommand(
        commandType: .purchaseV4,
        status: .pending,
        data: purchaseDataV4.getData()
      )
      SKServiceRegistry.commandStore.saveCommand(purchaseV4Command)
    }
    
    // Just no need to send receipt for duplicated product identifiers
    let productIdentifiers = transactionIds
    for productId in productIdentifiers {
      // default is true bacause we may not have [SKProduct] and purchase might be not subscription
      // server should have each updated receipt at this case not to lose one time puchases
      // no needs to send receipt for subscription purchases
      var shouldSendPurchase = true
      if let product = fetchProduct(by: productId),
         product.subscription?.introductoryOffer != nil {
        shouldSendPurchase = false
      }
      
      if shouldSendPurchase {
        let purchaseDataV4 = Purchaseapi_ReceiptRequest(
          storefront: countryCode,
          region: await Storefront.current?.countryCode,
          currency: allProducts?.first?.priceFormatStyle.currencyCode,
          newTransactions: transactionIds,
          docFolderDate: installData?.docDate,
          appBuildDate: installData?.buildDate
        )
        let purchaseV4Command = SKCommand(
          commandType: .setReceipt,
          status: .pending,
          data: purchaseDataV4.getData()
        )
        SKServiceRegistry.commandStore.saveCommand(purchaseV4Command)
      }
    }
    
    // Always sends transactions even in case if it was the first purchase
    // and transactions are included into purchase command
    let newTransactions = SKServiceRegistry.commandStore.getNewTransactionIds(transactionIds)
    if !newTransactions.isEmpty {
      let installData = SKServiceRegistry.commandStore.getDeviceRequest()
      let transactionDataV4 = Purchaseapi_TransactionsRequest(
        newTransactions: newTransactions,
        docFolderDate: installData?.docDate,
        appBuildDate: installData?.buildDate
      )
      let transactionV4Command = SKCommand(
        commandType: .transactionV4,
        status: .pending,
        data: transactionDataV4.getData()
      )
      SKServiceRegistry.commandStore.saveCommand(transactionV4Command)
    }
  }
}
