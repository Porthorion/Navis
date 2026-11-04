import Cocoa
import FlutterMacOS
import XCTest

@testable import Navis

class RunnerTests: XCTestCase {

  private func titles(_ menu: NSMenu?) -> [String] {
    return menu?.items.map { $0.title } ?? []
  }

  func testDockMenuWithNothingLoadedListsOnlyTransportItems() {
    let delegate = AppDelegate()
    let menu = delegate.applicationDockMenu(NSApp)
    XCTAssertEqual(titles(menu), ["Play", "Next", "Previous"])
    XCTAssertTrue(menu?.items.allSatisfy { $0.isEnabled } ?? false)
  }

  func testDockMenuShowsDisabledNowPlayingThenLocalizedTransportItems() {
    let delegate = AppDelegate()
    delegate.applyDockMenuUpdate([
      "hasItem": true,
      "title": "Song",
      "artist": "Band",
      "playing": true,
      "playPauseLabel": "Pause",
      "nextLabel": "Suivant",
      "previousLabel": "Précédent",
    ])
    let menu = delegate.applicationDockMenu(NSApp)
    XCTAssertEqual(titles(menu), ["Song — Band", "Pause", "Suivant", "Précédent"])
    XCTAssertFalse(menu!.items[0].isEnabled)
    XCTAssertTrue(menu!.items[1...].allSatisfy { $0.isEnabled })
    XCTAssertEqual(menu!.items[1].representedObject as? String, "playPause")
    XCTAssertEqual(menu!.items[2].representedObject as? String, "next")
    XCTAssertEqual(menu!.items[3].representedObject as? String, "previous")
  }

  func testDockMenuOmitsEmptyArtistSeparator() {
    let delegate = AppDelegate()
    delegate.applyDockMenuUpdate(["hasItem": true, "title": "Radio One", "artist": ""])
    XCTAssertEqual(titles(delegate.applicationDockMenu(NSApp)).first, "Radio One")
  }

  func testClosingTheLastWindowDoesNotQuit() {
    XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
  }
}
