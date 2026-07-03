import Foundation

/// CIE 1931 xy 色空間の色度座標。
struct CIEXYColor: Codable, Equatable {
    var x: Double
    var y: Double

    /// Hue の色域における赤の近似値
    static let red = CIEXYColor(x: 0.675, y: 0.322)
}
