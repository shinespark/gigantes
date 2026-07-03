import Foundation

/// CIE 1931 xy 色空間の色度座標。
struct CIEXYColor: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    /// Hue の色域における赤の近似値
    static let red = CIEXYColor(x: 0.675, y: 0.322)

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// sRGB (各成分 0–1) から変換する(Hue 開発者ドキュメントの手順)。
    init(red: Double, green: Double, blue: Double) {
        func linearize(_ c: Double) -> Double {
            c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
        }
        let r = linearize(red)
        let g = linearize(green)
        let b = linearize(blue)
        let bigX = r * 0.4124 + g * 0.3576 + b * 0.1805
        let bigY = r * 0.2126 + g * 0.7152 + b * 0.0722
        let bigZ = r * 0.0193 + g * 0.1192 + b * 0.9505
        let sum = bigX + bigY + bigZ
        if sum == 0 {
            // 黒は色度が定義できないため sRGB の白色点にフォールバック
            self.init(x: 0.3127, y: 0.3290)
        } else {
            self.init(x: bigX / sum, y: bigY / sum)
        }
    }
}

// MARK: - CLIP v2 リソース

/// CLIP v2 のレスポンス共通形式 `{"errors": [...], "data": [...]}`。
struct HueEnvelope<Resource: Decodable>: Decodable {
    struct ResourceError: Decodable {
        let description: String
    }

    let errors: [ResourceError]
    let data: [Resource]
}

/// `GET /clip/v2/resource/light` の light リソース(必要なフィールドのみ)。
struct HueLight: Decodable, Identifiable, Equatable {
    struct Metadata: Codable, Equatable {
        var name: String
    }
    struct On: Codable, Equatable {
        var on: Bool
    }
    struct Dimming: Codable, Equatable {
        var brightness: Double
    }
    struct ColorValue: Codable, Equatable {
        var xy: CIEXYColor
    }

    let id: String
    var metadata: Metadata?
    var on: On?
    var dimming: Dimming?
    var color: ColorValue?

    var displayName: String {
        let name = metadata?.name ?? ""
        return name.isEmpty ? id : name
    }
}

/// `PUT /clip/v2/resource/light/<id>` の body。nil のフィールドは送信しない。
struct HueLightUpdate: Encodable, Equatable {
    var on: HueLight.On?
    var dimming: HueLight.Dimming?
    var color: HueLight.ColorValue?

    init(settings: LightSettings) {
        on = settings.isOn.map(HueLight.On.init(on:))
        dimming = settings.brightness.map(HueLight.Dimming.init(brightness:))
        color = settings.color.map(HueLight.ColorValue.init(xy:))
    }
}

// MARK: - ペアリング(v1 API)

/// `POST /api` のレスポンス要素。success か error のどちらかが入る。
struct HuePairingResponseItem: Decodable {
    struct Success: Decodable {
        let username: String
    }
    struct APIError: Decodable {
        static let linkButtonNotPressed = 101

        let type: Int
        let description: String
    }

    let success: Success?
    let error: APIError?
}
