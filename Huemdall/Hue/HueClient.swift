import Foundation

struct HueAPIError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum PairingAttemptResult: Equatable {
    case success(applicationKey: String)
    case linkButtonNotPressed
}

/// Hue Bridge の CLIP API v2 クライアント。
struct HueClient: HueControlling {
    let bridgeIP: String
    let applicationKey: String?
    private let session: URLSession

    /// - Parameter protocolClasses: テストで URLProtocol スタブを差し込むための口
    init(
        bridgeIP: String,
        bridgeID: String,
        applicationKey: String?,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.bridgeIP = bridgeIP
        self.applicationKey = applicationKey

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(
            configuration: configuration,
            delegate: HueTLSDelegate(bridgeID: bridgeID),
            delegateQueue: nil
        )
    }

    // MARK: - ペアリング(v1 API)

    /// application key の取得を 1 回試行する。
    /// リンクボタン未押下(error type 101)は失敗ではなく `.linkButtonNotPressed` を返すので、
    /// 呼び出し側(設定画面)が数秒間隔でポーリングする。
    func attemptPairing() async throws -> PairingAttemptResult {
        let devicetype = "Huemdall#\(Host.current().localizedName ?? "mac")"
        var request = URLRequest(url: URL(string: "https://\(bridgeIP)/api")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["devicetype": devicetype])

        let (data, _) = try await session.data(for: request)
        let items = try JSONDecoder().decode([HuePairingResponseItem].self, from: data)

        if let username = items.compactMap(\.success).first?.username {
            return .success(applicationKey: username)
        }
        if let error = items.compactMap(\.error).first {
            if error.type == HuePairingResponseItem.APIError.linkButtonNotPressed {
                return .linkButtonNotPressed
            }
            throw HueAPIError(message: error.description)
        }
        throw HueAPIError(message: "Unexpected pairing response")
    }

    // MARK: - CLIP v2

    func listLights() async throws -> [HueLight] {
        try await get([HueLight].self, path: "resource/light")
    }

    func currentSettings(lightID: String) async throws -> LightSettings {
        let lights = try await get([HueLight].self, path: "resource/light/\(lightID)")
        guard let light = lights.first else {
            throw HueAPIError(message: "Light \(lightID) not found")
        }
        // 色温度モードのライトは mirek で捕捉する(xy だと近似色になり、復元でモードも変わってしまう)
        let mirekValid = light.colorTemperature?.mirekValid ?? false
        return LightSettings(
            isOn: light.on?.on,
            color: mirekValid ? nil : light.color?.xy,
            brightness: light.dimming?.brightness,
            mirek: mirekValid ? light.colorTemperature?.mirek : nil
        )
    }

    // MARK: - シーン

    func listScenes() async throws -> [HueScene] {
        try await get([HueScene].self, path: "resource/scene")
    }

    /// room と zone をまとめて返す(シーンの所属グループ名の表示用)。
    func listGroups() async throws -> [HueGroup] {
        let rooms = try await get([HueGroup].self, path: "resource/room")
        let zones = try await get([HueGroup].self, path: "resource/zone")
        return rooms + zones
    }

    func sceneLightIDs(sceneID: String) async throws -> [String] {
        let scenes = try await get([HueScene].self, path: "resource/scene/\(sceneID)")
        guard let scene = scenes.first else {
            throw HueAPIError(message: "Scene \(sceneID) not found")
        }
        return scene.targetLightIDs
    }

    func recallScene(sceneID: String) async throws {
        var request = try clipRequest(path: "resource/scene/\(sceneID)")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(HueSceneRecall.active)

        let (data, response) = try await session.data(for: request)
        try Self.checkErrors(data: data, response: response)
    }

    func apply(_ settings: LightSettings, to lightID: String) async throws {
        var request = try clipRequest(path: "resource/light/\(lightID)")
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(HueLightUpdate(settings: settings))

        let (data, response) = try await session.data(for: request)
        try Self.checkErrors(data: data, response: response)
    }

    // MARK: - 内部処理

    private func get<Resource: Decodable>(_ type: [Resource].Type, path: String) async throws -> [Resource] {
        let request = try clipRequest(path: path)
        let (data, response) = try await session.data(for: request)
        try Self.checkErrors(data: data, response: response)
        return try JSONDecoder().decode(HueEnvelope<Resource>.self, from: data).data
    }

    private func clipRequest(path: String) throws -> URLRequest {
        guard let applicationKey else {
            throw HueAPIError(message: "Not paired with the bridge")
        }
        var request = URLRequest(url: URL(string: "https://\(bridgeIP)/clip/v2/\(path)")!)
        request.setValue(applicationKey, forHTTPHeaderField: "hue-application-key")
        return request
    }

    private static func checkErrors(data: Data, response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // エラー詳細が envelope に入っていればそれを優先する
            if let envelope = try? JSONDecoder().decode(HueEnvelope<HueLight>.self, from: data),
               let first = envelope.errors.first {
                throw HueAPIError(message: first.description)
            }
            throw HueAPIError(message: "Bridge returned HTTP \(http.statusCode)")
        }
    }
}
