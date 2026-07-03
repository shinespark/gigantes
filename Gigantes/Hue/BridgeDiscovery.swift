import Foundation
import Network
import dnssd

struct DiscoveredBridge: Identifiable, Equatable, Sendable {
    /// Bridge ID(小文字)。TLS の CN 照合と Keychain のアカウント名に使う
    let id: String
    let ip: String
}

enum DiscoveryError: LocalizedError {
    /// macOS 15+ でローカルネットワークへのアクセスが拒否されている
    case localNetworkDenied

    var errorDescription: String? {
        switch self {
        case .localNetworkDenied:
            String(localized: "Local network access is denied. Allow Gigantes in System Settings > Privacy & Security > Local Network.")
        }
    }
}

/// Hue Bridge の発見。mDNS(`_hue._tcp`)を第一候補とし、
/// 失敗時のみ discovery.meethue.com にフォールバックする(レート制限 ~1req/15min)。
struct BridgeDiscovery: Sendable {
    func discover(timeout: Duration = .seconds(5)) async throws -> [DiscoveredBridge] {
        let viaMDNS = try await discoverViaMDNS(timeout: timeout)
        if !viaMDNS.isEmpty {
            return viaMDNS
        }
        return await discoverViaCloud()
    }

    // MARK: - mDNS

    func discoverViaMDNS(timeout: Duration = .seconds(5)) async throws -> [DiscoveredBridge] {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: nil),
            using: NWParameters()
        )
        defer { browser.cancel() }

        // timeout の間 browse し、見つかったサービスの TXT から bridgeid を取り出す
        let found: [(bridgeID: String, endpoint: NWEndpoint)] = try await withCheckedThrowingContinuation { continuation in
            let state = LockedState()
            browser.stateUpdateHandler = { browserState in
                if case .waiting(let error) = browserState,
                   case .dns(let code) = error,
                   code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                    state.finish { continuation.resume(throwing: DiscoveryError.localNetworkDenied) }
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                let bridges: [(String, NWEndpoint)] = results.compactMap { result in
                    guard case .bonjour(let txt) = result.metadata,
                          let bridgeID = txt["bridgeid"], !bridgeID.isEmpty else {
                        return nil
                    }
                    return (bridgeID.lowercased(), result.endpoint)
                }
                if !bridges.isEmpty {
                    state.finish { continuation.resume(returning: bridges) }
                }
            }
            browser.start(queue: .global())

            Task {
                try? await Task.sleep(for: timeout)
                state.finish { continuation.resume(returning: []) }
            }
        }

        var bridges: [DiscoveredBridge] = []
        for (bridgeID, endpoint) in found {
            if let ip = await resolveIPv4(of: endpoint) {
                bridges.append(DiscoveredBridge(id: bridgeID, ip: ip))
            }
        }
        return bridges
    }

    /// Bonjour サービスエンドポイントに一度接続して IPv4 アドレスを得る。
    private func resolveIPv4(of endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let state = LockedState()
            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    var ip: String?
                    if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint,
                       case .ipv4(let address) = host {
                        // リンクローカルのインターフェース修飾(%en0)は URL に使えないため除く
                        ip = "\(address)".components(separatedBy: "%").first
                    }
                    state.finish { continuation.resume(returning: ip) }
                    connection.cancel()
                case .failed, .cancelled:
                    state.finish { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    // MARK: - クラウドフォールバック

    private struct CloudBridge: Decodable {
        let id: String
        let internalipaddress: String
    }

    private func discoverViaCloud() async -> [DiscoveredBridge] {
        guard let url = URL(string: "https://discovery.meethue.com"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let bridges = try? JSONDecoder().decode([CloudBridge].self, from: data) else {
            return []
        }
        return bridges.map { DiscoveredBridge(id: $0.id.lowercased(), ip: $0.internalipaddress) }
    }
}

/// continuation の二重 resume を防ぐための最小限のロック。
private final class LockedState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        body()
    }
}
