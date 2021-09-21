import Foundation
import CoreBluetooth
import os.log

/// An object that scans for, discovers, connects to, and manages peripherals using concurrency.
public class CentralManager {
    
    private typealias Utils = CentralManagerUtils
    
    fileprivate class DelegateWrapper: NSObject {
        private let context: CentralManagerContext
        
        init(context: CentralManagerContext) {
            self.context = context
        }
    }
    
    private static let logger = Logger(
        subsystem: Bundle(for: CentralManager.self).bundleIdentifier ?? "",
        category: "centralManager"
    )
    
    public var bluetoothState: CBManagerState {
        self.cbCentralManager.state
    }
    
    public var isScanning: Bool {
        switch self.context.scanState {
        case .notScanning:
            return false
        default:
            return true
        }
    }
    
    private let cbCentralManager: CBCentralManager
    private let context: CentralManagerContext
    private let cbCentralManagerDelegate: CBCentralManagerDelegate
    
    // MARK: Constructors

    public init(dispatchQueue: DispatchQueue? = nil, options: [String: Any]? = nil) {
        self.cbCentralManager = CBCentralManager(delegate: nil, queue: dispatchQueue, options: options)
        self.context = CentralManagerContext()
        self.cbCentralManagerDelegate = DelegateWrapper(context: self.context)
        self.cbCentralManager.delegate = self.cbCentralManagerDelegate
    }
    
    // MARK: Public
    
    /// Waits until Bluetooth is ready. If the Bluetooth state is unknown or resetting, it
    /// will wait until a `centralManagerDidUpdateState` message is received. If Bluetooth is powered off,
    /// unsupported or unauthorized, an error will be thrown. Otherwise we'll continue.
    public func waitUntilReady() async throws {
        guard let isBluetoothReadyResult = Utils.isBluetoothReady(self.bluetoothState) else {
            Self.logger.info("Waiting for bluetooth to be ready...")
            
            try await self.context.waitUntilReadyExecutor.enqueue {}
            return
        }

        switch isBluetoothReadyResult {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }
    
    /// Scans for peripherals that are advertising services.
    public func scanForPeripherals(
        withServices serviceUUIDs: [CBUUID]?,
        options: [String : Any]? = nil
    ) throws -> AsyncStream<ScanData> {
        guard !self.isScanning else {
            Self.logger.error("Scanning failed: already in progress")
            throw BluetoothError.scanningInProgress
        }
        
        self.context.scanState = .awaiting
        
        return AsyncStream(ScanData.self) { continuation in
            continuation.onTermination = { @Sendable _ in
                self.cbCentralManager.stopScan()
                self.context.scanState = .notScanning
                
                Self.logger.info("Stopped scanning peripherals")
            }
            
            self.context.scanState = .scanning(continuation: continuation)
            
            self.cbCentralManager.scanForPeripherals(withServices: serviceUUIDs, options: options)
            
            Self.logger.info("Scanning for peripherals...")
        }
    }
    
    /// Asks the central manager to stop scanning for peripherals.
    public func stopScan() {
        guard case ScanState.scanning(let continuation) = self.context.scanState else {
            Self.logger.warning("Unable to stop scanning because the central manager is not scanning!")
            return
        }
        
        Self.logger.info("Stopping scan...")
        
        continuation.finish()
    }
    
    /// Establishes a local connection to a peripheral.
    public func connect(_ peripheral: Peripheral, options: [String : Any]? = nil) async throws {
        guard await !self.context.connectToPeripheralExecutor.hasWorkForKey(peripheral.identifier) else {
            Self.logger.error("Unable to connect to \(peripheral.identifier) because a connection attempt is already in progress")

            throw BluetoothError.connectingInProgress
        }
        
        try await self.context.connectToPeripheralExecutor.enqueue(withKey: peripheral.identifier) {
            Self.logger.info("Connecting to \(peripheral.identifier)")
            
            self.cbCentralManager.connect(peripheral.cbPeripheral, options: options)
        }
    }
    
    /// Cancels an active or pending local connection to a peripheral.
    public func cancelPeripheralConnection(_ peripheral: Peripheral) async throws {
        let peripheralState = peripheral.cbPeripheral.state
        guard peripheralState == CBPeripheralState.connecting || peripheralState == CBPeripheralState.connected else {
            Self.logger.error("Unable to cancel connection: no connection to peripheral \(peripheral.identifier) exists nor being attempted")
            throw BluetoothError.noConnectionToPeripheralExists
        }
        
        guard await !self.context.cancelPeripheralConnectionExecutor.hasWorkForKey(peripheral.identifier) else {
            Self.logger.error("Unable to disconnect from \(peripheral.identifier) because a disconnection attempt is already in progress")

            throw BluetoothError.disconnectingInProgress
        }

        try await self.context.cancelPeripheralConnectionExecutor.enqueue(withKey: peripheral.identifier) {
            Self.logger.info("Disconnecting from \(peripheral.identifier)")
            
            self.cbCentralManager.cancelPeripheralConnection(peripheral.cbPeripheral)
        }
    }
    
    /// Returns a list of known peripherals by their identifiers.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [Peripheral] {
        self.cbCentralManager.retrievePeripherals(withIdentifiers: identifiers).map { Peripheral($0) }
    }
    
    /// Returns a list of the peripherals connected to the system whose services match a given set of criteria.
    public func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [Peripheral] {
        self.cbCentralManager.retrieveConnectedPeripherals(withServices: serviceUUIDs).map { Peripheral($0) }
    }

    /// Returns a Boolean that indicates whether the device supports a specific set of features.
    @available(macOS, unavailable)
    public static func supports(_ features: CBCentralManager.Feature) -> Bool {
        CBCentralManager.supports(features)
    }
}

// MARK: CBCentralManagerDelegate

extension CentralManager.DelegateWrapper: CBCentralManagerDelegate {
    private typealias Utils = CentralManagerUtils
    
    private static var logger: Logger = {
        CentralManager.logger
    }()
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task {
            guard let isBluetoothReadyResult = Utils.isBluetoothReady(central.state) else { return }

            await self.context.waitUntilReadyExecutor.flush(isBluetoothReadyResult)
        }
    }
    
    func centralManager(
        _ cbCentralManager: CBCentralManager,
        didDiscover cbPeripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        let scanData = ScanData(
            peripheral: Peripheral(cbPeripheral),
            advertisementData: advertisementData,
            rssi: RSSI
        )
        guard case ScanState.scanning(let continuation) = self.context.scanState else {
            Self.logger.info("Ignoring peripheral '\(scanData.peripheral.name ?? "unknown", privacy: .private)' because the central manager is not scanning")
            return
        }
        continuation.yield(scanData)
        
        Self.logger.info("Found peripheral \(scanData.peripheral.identifier)")
    }
    
    func centralManager(_ cbCentralManager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task {
            Self.logger.info("Connected to peripheral \(peripheral.identifier)")
            
            do {
                try await self.context.connectToPeripheralExecutor.setWorkCompletedForKey(
                    peripheral.identifier, result:.success(())
                )
            } catch {
                Self.logger.error("Received onDidConnect without a continuation!")
            }
        }
    }
    
    func centralManager(
        _ cbCentralManager: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task {
            Self.logger.warning(
                "Failed to connect to peripheral \(peripheral.identifier) - error: \(error?.localizedDescription ?? "")"
            )
            
            do {
                try await self.context.connectToPeripheralExecutor.setWorkCompletedForKey(
                    peripheral.identifier, result: .failure(BluetoothError.errorConnectingToPeripheral(error: error))
                )
            } catch {
                Self.logger.error("Received onDidFailToConnect without a continuation!")
            }
        }
    }
    
    func centralManager(
        _ cbCentralManager: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task {
            do {
                let result = CallbackUtils.result(for: (), error: error)
                try await self.context.cancelPeripheralConnectionExecutor.setWorkCompletedForKey(
                    peripheral.identifier, result: result
                )
                Self.logger.info("Disconnected from \(peripheral.identifier)")
            } catch {
                Self.logger.info("Disconnected from \(peripheral.identifier) without a continuation")
            }
        }
    }
}