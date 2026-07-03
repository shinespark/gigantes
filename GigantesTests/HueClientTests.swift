import XCTest
@testable import Gigantes

/// URLSession に差し込んで、リクエストの検査と固定レスポンスの返却を行うスタブ。
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            fatalError("StubURLProtocol.handler not set")
        }
        // httpBody は URLProtocol 到達時に httpBodyStream へ変換されるため、そちらから読む
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            stream.close()
            request.httpBody = data
        }

        let (statusCode, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HueClientTests: XCTestCase {
    private func makeClient(applicationKey: String? = "test-key") -> HueClient {
        HueClient(
            bridgeIP: "192.0.2.1",
            bridgeID: "0123456789abcdef",
            applicationKey: applicationKey,
            protocolClasses: [StubURLProtocol.self]
        )
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - apply(PUT)

    func testApplyEncodesNestedClipV2Payload() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, Data(#"{"errors": [], "data": []}"#.utf8))
        }

        let settings = LightSettings(
            isOn: true,
            color: CIEXYColor(x: 0.675, y: 0.322),
            brightness: 100
        )
        try await makeClient().apply(settings, to: "light-uuid")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://192.0.2.1/clip/v2/resource/light/light-uuid")
        XCTAssertEqual(request.value(forHTTPHeaderField: "hue-application-key"), "test-key")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["on"] as? [String: Any])?["on"] as? Bool, true)
        XCTAssertEqual((json["dimming"] as? [String: Any])?["brightness"] as? Double, 100)
        let xy = try XCTUnwrap((json["color"] as? [String: Any])?["xy"] as? [String: Any])
        XCTAssertEqual(xy["x"] as? Double, 0.675)
        XCTAssertEqual(xy["y"] as? Double, 0.322)
    }

    func testApplyOmitsNilFields() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, Data(#"{"errors": [], "data": []}"#.utf8))
        }

        try await makeClient().apply(LightSettings(isOn: false), to: "light-uuid")

        let body = try XCTUnwrap(captured?.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["on"])
    }

    func testApplyWithoutApplicationKeyThrows() async {
        do {
            try await makeClient(applicationKey: nil).apply(LightSettings(isOn: true), to: "light-uuid")
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is HueAPIError)
        }
    }

    // MARK: - currentSettings(GET)

    func testCurrentSettingsDecodesLightResource() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data("""
            {"errors": [], "data": [{
                "id": "light-uuid",
                "metadata": {"name": "Desk lamp"},
                "on": {"on": true},
                "dimming": {"brightness": 42.5},
                "color": {"xy": {"x": 0.4, "y": 0.35}}
            }]}
            """.utf8))
        }

        let settings = try await makeClient().currentSettings(lightID: "light-uuid")

        XCTAssertEqual(settings.isOn, true)
        XCTAssertEqual(settings.brightness, 42.5)
        XCTAssertEqual(settings.color, CIEXYColor(x: 0.4, y: 0.35))
    }

    // MARK: - ペアリング

    func testAttemptPairingReturnsLinkButtonNotPressedForError101() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"[{"error": {"type": 101, "address": "", "description": "link button not pressed"}}]"#.utf8))
        }

        let result = try await makeClient(applicationKey: nil).attemptPairing()

        XCTAssertEqual(result, .linkButtonNotPressed)
    }

    func testAttemptPairingReturnsApplicationKeyOnSuccess() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, Data(#"[{"success": {"username": "abc123", "clientkey": "xyz"}}]"#.utf8))
        }

        let result = try await makeClient(applicationKey: nil).attemptPairing()

        XCTAssertEqual(result, .success(applicationKey: "abc123"))
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.absoluteString, "https://192.0.2.1/api")
    }
}

final class HueTLSDelegateTests: XCTestCase {
    func testBundledRootCACanBeLoaded() throws {
        let anchors = HueTLSDelegate.bundledAnchors()

        XCTAssertEqual(anchors.count, 1, "hue-root-ca.pem がアプリバンドルに含まれていること")
        var commonName: CFString?
        XCTAssertEqual(SecCertificateCopyCommonName(try XCTUnwrap(anchors.first), &commonName), errSecSuccess)
        XCTAssertEqual(commonName as String?, "root-bridge")
    }
}
