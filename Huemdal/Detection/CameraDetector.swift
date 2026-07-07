import CoreMediaIO
import Foundation
import os

/// CoreMediaIO でシステム上の全ビデオデバイスを監視し、
/// 「いずれかのカメラをどこかのプロセスが使用中か」を通知する。
///
/// - `kCMIODevicePropertyDeviceIsRunningSomewhere` を読むだけで映像には触れないため、
///   カメラ利用許可(TCC)ダイアログは発生しない
/// - リスナーは変化のみ通知するため、購読開始時とデバイス増減時に現在値を明示的に読む
/// - リスナーブロックの削除には既知の不具合報告(FB13398940)があるため、
///   一度登録したリスナーは外さず、デバイス増減は再列挙・再読取で追従する
final class CameraDetector: ActivityDetector, @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.shinespark.huemdal", category: "CameraDetector")

    /// 全ミュータブル状態はこの serial queue 上でのみ触る(リスナーブロックも同じ queue で呼ばれる)
    private let queue = DispatchQueue(label: "dev.shinespark.huemdal.camera-detector")
    private var listenedDevices: Set<CMIOObjectID> = []
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var lastValue: Bool?
    private var started = false

    var isActive: AsyncStream<Bool> {
        AsyncStream { continuation in
            queue.async {
                self.startIfNeeded()
                let id = UUID()
                self.continuations[id] = continuation
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.continuations[id] = nil }
                }
                let current = self.anyCameraRunning()
                self.lastValue = current
                continuation.yield(current)
            }
        }
    }

    // MARK: - CMIO(queue 上でのみ呼ぶ)

    private func startIfNeeded() {
        guard !started else { return }
        started = true

        var address = Self.propertyAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let status = CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &address, queue
        ) { [weak self] _, _ in
            self?.attachDeviceListeners()
            self?.emitIfChanged()
        }
        if status != kCMIOHardwareNoError {
            Self.logger.error("Failed to add hardware devices listener: \(status)")
        }
        attachDeviceListeners()
    }

    private func attachDeviceListeners() {
        for device in currentDeviceIDs() where !listenedDevices.contains(device) {
            var address = Self.propertyAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            guard CMIOObjectHasProperty(device, &address) else { continue }

            let status = CMIOObjectAddPropertyListenerBlock(device, &address, queue) { [weak self] _, _ in
                self?.emitIfChanged()
            }
            if status == kCMIOHardwareNoError {
                listenedDevices.insert(device)
            } else {
                Self.logger.error("Failed to add listener for device \(device): \(status)")
            }
        }
    }

    private func emitIfChanged() {
        let current = anyCameraRunning()
        guard current != lastValue else { return }
        lastValue = current
        Self.logger.info("Camera running somewhere: \(current)")
        for continuation in continuations.values {
            continuation.yield(current)
        }
    }

    private func anyCameraRunning() -> Bool {
        currentDeviceIDs().contains { isRunningSomewhere($0) }
    }

    private func currentDeviceIDs() -> [CMIOObjectID] {
        var address = Self.propertyAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var dataSize: UInt32 = 0
        let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == kCMIOHardwareNoError,
              dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var deviceIDs = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(systemObject, &address, 0, nil, dataSize, &dataUsed, &deviceIDs) == kCMIOHardwareNoError else {
            return []
        }
        return deviceIDs
    }

    private func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = Self.propertyAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        guard CMIOObjectHasProperty(device, &address) else { return false }
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == kCMIOHardwareNoError,
              dataSize == UInt32(MemoryLayout<UInt32>.size) else {
            return false
        }
        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &dataUsed, &value) == kCMIOHardwareNoError else {
            return false
        }
        return value != 0
    }

    private static func propertyAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }
}
