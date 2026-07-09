import XCTest
@testable import Huemdall

final class SnapshotStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "dev.shinespark.huemdall.tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSaveLoadRoundTrip() {
        let store = UserDefaultsSnapshotStore(defaults: defaults)
        let snapshots = [
            LightSnapshot(
                lightID: "light-1",
                isOn: true,
                colorXY: CIEXYColor(x: 0.4, y: 0.35),
                brightness: 42.5,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            LightSnapshot(
                lightID: "light-2",
                isOn: false,
                colorXY: nil,
                brightness: nil,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_001)
            ),
        ]

        store.save(snapshots)

        XCTAssertEqual(store.load(), snapshots)
    }

    func testLoadReturnsEmptyWhenNothingSaved() {
        XCTAssertEqual(UserDefaultsSnapshotStore(defaults: defaults).load(), [])
    }

    func testSnapshotWithoutMirekKeyDecodes() throws {
        // mirek フィールド追加前に保存されたスナップショットも読めること
        let legacyJSON = Data("""
        [{
            "lightID": "light-1",
            "isOn": true,
            "colorXY": {"x": 0.4, "y": 0.35},
            "brightness": 42.5,
            "capturedAt": 700000000
        }]
        """.utf8)

        let snapshots = try JSONDecoder().decode([LightSnapshot].self, from: legacyJSON)

        XCTAssertEqual(snapshots.first?.lightID, "light-1")
        XCTAssertNil(snapshots.first?.mirek)
    }

    func testClearRemovesSnapshots() {
        let store = UserDefaultsSnapshotStore(defaults: defaults)
        store.save([LightSnapshot(
            lightID: "light-uuid", isOn: false, colorXY: nil, brightness: nil, capturedAt: Date()
        )])

        store.clear()

        XCTAssertEqual(store.load(), [])
    }
}
