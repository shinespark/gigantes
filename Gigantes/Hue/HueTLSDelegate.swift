import Foundation
import Security

/// Hue Bridge の TLS 証明書検証。
///
/// Bridge の証明書は公開 CA ではなく Signify のプライベート CA から発行されるため、
/// バンドルしたルート CA だけをアンカーとして検証する。IP 直指定で接続するため
/// ホスト名検証は通らず、代わりに leaf 証明書の CN と Bridge ID の一致を確認する。
/// 検証を無効化するだけの実装は採用しない(設計ドキュメント 5.3)。
final class HueTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let bridgeID: String
    private let anchors: [SecCertificate]

    init(bridgeID: String, anchors: [SecCertificate] = HueTLSDelegate.bundledAnchors()) {
        self.bridgeID = bridgeID.lowercased()
        self.anchors = anchors
    }

    /// アプリにバンドルした Signify ルート CA(hue-root-ca.pem)を読み込む。
    static func bundledAnchors(bundle: Bundle = .main) -> [SecCertificate] {
        guard let url = bundle.url(forResource: "hue-root-ca", withExtension: "pem"),
              let pem = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return certificates(fromPEM: pem)
    }

    static func certificates(fromPEM pem: String) -> [SecCertificate] {
        pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").compactMap { chunk in
            guard let end = chunk.range(of: "-----END CERTIFICATE-----") else { return nil }
            let base64 = chunk[..<end.lowerBound]
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            guard let der = Data(base64Encoded: base64) else { return nil }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              validate(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func validate(_ trust: SecTrust) -> Bool {
        guard !anchors.isEmpty,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              // ホスト名なしの SSL ポリシーに差し替え、後段の CN 照合で代替する
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil)) == errSecSuccess else {
            return false
        }

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            // 古いファームウェアの自己署名証明書もここで弾かれる(検証は緩めない)
            return false
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return false
        }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess,
              let commonName else {
            return false
        }
        return (commonName as String).lowercased() == bridgeID
    }
}
