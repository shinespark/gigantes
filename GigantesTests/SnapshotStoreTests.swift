import XCTest
@testable import Gigantes

final class SnapshotStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "dev.shinespark.gigantes.tests"

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
        let snapshot = LightSnapshot(
            lightID: "light-uuid",
            isOn: true,
            colorXY: CIEXYColor(x: 0.4, y: 0.35),
            brightness: 42.5,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
    }

    func testLoadReturnsNilWhenEmpty() {
        XCTAssertNil(UserDefaultsSnapshotStore(defaults: defaults).load())
    }

    func testClearRemovesSnapshot() {
        let store = UserDefaultsSnapshotStore(defaults: defaults)
        store.save(LightSnapshot(
            lightID: "light-uuid", isOn: false, colorXY: nil, brightness: nil, capturedAt: Date()
        ))

        store.clear()

        XCTAssertNil(store.load())
    }
}
