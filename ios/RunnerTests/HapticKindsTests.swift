import UIKit
import XCTest

@testable import Runner

/// Mirrors `HapticKindsTest.kt`: every kind of the haptic vocabulary in
/// `navis_haptics.dart` has its own feel.
class HapticKindsTests: XCTestCase {
  private let allKinds = [
    "toggleOn", "toggleOff", "press", "release", "firm", "tick", "frequentTick",
    "contextClick", "confirm", "reject", "thresholdOn", "thresholdOff", "dragStart",
    "dragEnd", "longPress",
  ]

  func testEveryKindHasItsOwnSpec() {
    var seen: [String: HapticSpec] = [:]
    for kind in allKinds {
      let spec = HapticKinds.spec(for: kind)
      for (other, otherSpec) in seen {
        XCTAssertNotEqual(spec, otherSpec, "\(kind) feels like \(other)")
      }
      seen[kind] = spec
    }
    XCTAssertEqual(seen.count, 15)
  }

  func testOutcomesUseTheNotificationFeedback() {
    XCTAssertEqual(HapticKinds.spec(for: "confirm"), .notification(.success))
    XCTAssertEqual(HapticKinds.spec(for: "reject"), .notification(.error))
  }

  func testTickUsesTheSelectionFeedback() {
    XCTAssertEqual(HapticKinds.spec(for: "tick"), .selection)
  }

  func testPairsAreOpposites() {
    func impact(_ kind: String) -> (UIImpactFeedbackGenerator.FeedbackStyle, CGFloat) {
      guard case let .impact(style, intensity) = HapticKinds.spec(for: kind) else {
        XCTFail("\(kind) is not an impact")
        return (.light, 0)
      }
      return (style, intensity)
    }
    XCTAssertEqual(impact("toggleOn").0, .rigid)
    XCTAssertEqual(impact("toggleOff").0, .soft)
    XCTAssertEqual(impact("thresholdOn").0, .rigid)
    XCTAssertEqual(impact("thresholdOff").0, .soft)
    XCTAssertGreaterThan(impact("press").1, impact("release").1)
    XCTAssertGreaterThan(impact("dragStart").1, impact("dragEnd").1)
    XCTAssertEqual(impact("longPress").0, .heavy)
  }

  func testUnknownKindFallsBackToALightImpact() {
    XCTAssertEqual(HapticKinds.spec(for: "nope"), .impact(.light, 1))
    XCTAssertEqual(HapticKinds.spec(for: ""), .impact(.light, 1))
  }

  func testIntensitiesStayInRange() {
    for kind in allKinds + ["nope"] {
      if case let .impact(_, intensity) = HapticKinds.spec(for: kind) {
        XCTAssertTrue((0...1).contains(intensity), kind)
      }
    }
  }
}
