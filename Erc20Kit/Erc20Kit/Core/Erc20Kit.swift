import RxSwift
import EthereumKit
import HSCryptoKit

public class Erc20Kit {
    private let gasLimit = 100_000

    private let disposeBag = DisposeBag()

    private let ethereumKit: EthereumKit
    private let transactionManager: ITransactionManager
    private let balanceManager: IBalanceManager
    private let tokenHolder: ITokenHolder

    init(ethereumKit: EthereumKit, transactionManager: ITransactionManager, balanceManager: IBalanceManager, tokenHolder: ITokenHolder = TokenHolder()) {
        self.ethereumKit = ethereumKit
        self.transactionManager = transactionManager
        self.balanceManager = balanceManager
        self.tokenHolder = tokenHolder
    }

    private func startTransactionsSync() {
        transactionManager.sync()
    }

    private func convert(address: String) throws -> Data {
        guard let contractAddress = Data(hex: address) else {
            throw TokenError.invalidAddress
        }

        return contractAddress
    }

    private func set(syncState: Erc20Kit.SyncState, contractAddress: Data) {
        try? tokenHolder.set(syncState: syncState, contractAddress: contractAddress)
        try? tokenHolder.delegate(contractAddress: contractAddress)?.onUpdateSyncState()
    }

    private func setAll(syncState: Erc20Kit.SyncState) {
        for contractAddress in tokenHolder.contractAddresses {
            set(syncState: syncState, contractAddress: contractAddress)
        }
    }

}

extension Erc20Kit {

    public func syncState(contractAddress: String) throws -> SyncState {
        return try tokenHolder.syncState(contractAddress: try convert(address: contractAddress))
    }

    public func balance(contractAddress: String) throws -> String {
        return try tokenHolder.balance(contractAddress: try convert(address: contractAddress)).value.asString(withBase: 10)
    }

    public func fee(gasPrice: Int) -> Decimal {
        return Decimal(gasPrice) * Decimal(gasLimit)
    }

    public func sendSingle(contractAddress: String, to: String, value: String, gasPrice: Int) throws -> Single<TransactionInfo> {
        let contractAddress = try convert(address: contractAddress)
        let to = try convert(address: to)

        guard let value = BInt(value, radix: 16) else {
            throw SendError.invalidValue
        }

        return transactionManager.sendSingle(contractAddress: contractAddress, to: to, value: value, gasPrice: gasPrice)
                .map({ TransactionInfo(transaction: $0) })
    }

    public func transactionsSingle(contractAddress: String, hashFrom: Data?, indexFrom: Int?, limit: Int?) throws -> Single<[TransactionInfo]> {
        return transactionManager.transactionsSingle(contractAddress: try convert(address: contractAddress), hashFrom: hashFrom, indexFrom: indexFrom, limit: limit)
                .map { transactions in
                    transactions.map {
                        TransactionInfo(transaction: $0)
                    }
                }
    }

    public func register(contractAddress: String, balancePosition: Int, delegate: IErc20TokenDelegate) throws {
        let contractAddress = try convert(address: contractAddress)
        let balance = balanceManager.balance(contractAddress: contractAddress)

        tokenHolder.register(contractAddress: contractAddress, balancePosition: balancePosition, balance: balance, delegate: delegate)
    }

    public func unregister(contractAddress: String) throws {
        let contractAddress = try convert(address: contractAddress)

        try tokenHolder.unregister(contractAddress: contractAddress)
    }

    public func clear() {
        tokenHolder.clear()
        transactionManager.clear()
        balanceManager.clear()
    }

}

extension Erc20Kit: IEthereumKitDelegate {

    public func onUpdateSyncState() {
        switch ethereumKit.syncState {
        case .notSynced: setAll(syncState: .notSynced)
        case .syncing: setAll(syncState: .syncing)
        case .synced: startTransactionsSync()
        }
    }

    public func onUpdateLastBlockHeight() {
        guard ethereumKit.syncState == .synced else {
            return
        }

        startTransactionsSync()
    }

    public func onClear() {
        clear()
    }

}

extension Erc20Kit: ITransactionManagerDelegate {

    func onSyncSuccess(transactions: [Transaction]) {
        let transactionsData: [Data: [Transaction]] = Dictionary(grouping: transactions, by: { $0.contractAddress })

        for (contractAddress, transactions) in transactionsData {
            try? tokenHolder.delegate(contractAddress: contractAddress)?.onUpdate(transactions: transactions.map { TransactionInfo(transaction: $0) })
        }

        for contractAddress in tokenHolder.contractAddresses {
            guard let balancePosition = try? tokenHolder.balancePosition(contractAddress: contractAddress) else {
                continue
            }

            if let lastTransactionBlockHeight = transactionManager.lastTransactionBlockHeight(contractAddress: contractAddress),
               lastTransactionBlockHeight > balanceManager.balance(contractAddress: contractAddress).blockHeight
            {
                balanceManager.sync(blockHeight: lastTransactionBlockHeight, contractAddress: contractAddress, balancePosition: balancePosition)
            } else {
                set(syncState: .synced, contractAddress: contractAddress)
            }
        }
    }

    func onSyncTransactionsError() {
        setAll(syncState: .notSynced)
    }

}

extension Erc20Kit: IBalanceManagerDelegate {

    func onSyncBalanceSuccess(contractAddress: Data) {
        set(syncState: .synced, contractAddress: contractAddress)
    }

    func onSyncBalanceError(contractAddress: Data) {
        set(syncState: .notSynced, contractAddress: contractAddress)
    }

    func onUpdate(balance: TokenBalance, contractAddress: Data) {
        try? tokenHolder.set(balance: balance, contractAddress: contractAddress)
        try? tokenHolder.delegate(contractAddress: contractAddress)?.onUpdateBalance()
    }

}

extension Erc20Kit {

    public static func instance(ethereumKit: EthereumKit, networkType: EthereumKit.NetworkType, etherscanApiKey: String, minLogLevel: Logger.Level = .verbose) -> Erc20Kit {
        let address = ethereumKit.receiveAddressData

        let storage: ITransactionStorage & ITokenBalanceStorage = GrdbStorage(databaseFileName: "erc20_tokens_db")

        let dataProvider: IDataProvider = DataProvider(ethereumKit: ethereumKit)
        let transactionBuilder: ITransactionBuilder = TransactionBuilder()
        var transactionManager: ITransactionManager = TransactionManager(address: address, storage: storage, dataProvider: dataProvider, transactionBuilder: transactionBuilder)
        var balanceManager: IBalanceManager = BalanceManager(address: address, storage: storage, dataProvider: dataProvider)

        let erc20Kit = Erc20Kit(ethereumKit: ethereumKit, transactionManager: transactionManager, balanceManager: balanceManager)

        transactionManager.delegate = erc20Kit
        balanceManager.delegate = erc20Kit

        ethereumKit.add(delegate: erc20Kit)

        return erc20Kit
    }

}

extension Erc20Kit {

    public enum TokenError: Error {
        case invalidAddress
        case notRegistered
        case alreadyRegistered
    }

    public enum SendError: Error {
        case invalidAddress
        case invalidContractAddress
        case invalidValue
    }

    public enum SyncState: Int {
        case notSynced = 0
        case syncing = 1
        case synced = 2
    }

}