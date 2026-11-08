import Cocoa
import FlutterMacOS
import XCTest

@testable import Navis

class RunnerTests: XCTestCase {

  private func titles(_ menu: NSMenu?) -> [String] {
    return menu?.items.map { $0.title } ?? []
  }

  func testNoDockMenuBeforeTheFirstUpdate() {
    XCTAssertNil(AppDelegate().applicationDockMenu(NSApp))
  }

  func testIncompleteUpdateIsIgnored() {
    let delegate = AppDelegate()
    delegate.applyDockMenuUpdate(["hasItem": true, "title": "Song"])
    XCTAssertNil(delegate.applicationDockMenu(NSApp))
  }

  func testDockMenuWithNothingLoadedListsOnlyTransportItems() {
    let delegate = AppDelegate()
    delegate.applyDockMenuUpdate([
      "hasItem": false,
      "playPauseLabel": "Play",
      "nextLabel": "Next",
      "previousLabel": "Previous",
    ])
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
    delegate.applyDockMenuUpdate([
      "hasItem": true, "title": "Radio One", "artist": "",
      "playPauseLabel": "Play", "nextLabel": "Next", "previousLabel": "Previous",
    ])
    XCTAssertEqual(titles(delegate.applicationDockMenu(NSApp)).first, "Radio One")
  }

  private func menuBarWithWindowMenu() -> NSMenu {
    let bar = NSMenu(title: "Main")
    let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    window.submenu = NSMenu(title: "Window")
    bar.addItem(window)
    NSApp.mainMenu = bar
    NSApp.windowsMenu = window.submenu
    return bar
  }

  func testControlsMenuIsInstalledOnceBeforeTheWindowMenuAndStartsDisabled() {
    let bar = menuBarWithWindowMenu()
    let delegate = AppDelegate()
    delegate.installControlsMenu()
    delegate.installControlsMenu()
    XCTAssertEqual(titles(bar), ["Controls", "Window"])
    XCTAssertEqual(titles(delegate.controlsMenu), ["Play", "Next", "Previous"])
    XCTAssertTrue(delegate.controlsMenu!.items.allSatisfy { !$0.isEnabled && $0.keyEquivalent == "" })
  }

  func testControlsMenuFollowsThePushedState() {
    let bar = menuBarWithWindowMenu()
    let delegate = AppDelegate()
    delegate.installControlsMenu()
    delegate.applyDockMenuUpdate([
      "hasItem": true, "playing": true, "playPauseLabel": "Pause",
      "nextLabel": "Suivant", "previousLabel": "Précédent", "controlsMenuLabel": "Commandes",
    ])
    XCTAssertEqual(titles(bar), ["Commandes", "Window"])
    XCTAssertEqual(titles(delegate.controlsMenu), ["Pause", "Suivant", "Précédent"])
    XCTAssertTrue(delegate.controlsMenu!.items.allSatisfy { $0.isEnabled })
    XCTAssertEqual(delegate.controlsMenu!.items.map { $0.representedObject as? String },
                   ["playPause", "next", "previous"])
    delegate.applyDockMenuUpdate([
      "hasItem": false, "playPauseLabel": "Play",
      "nextLabel": "Next", "previousLabel": "Previous", "controlsMenuLabel": "Controls",
    ])
    XCTAssertTrue(delegate.controlsMenu!.items.allSatisfy { !$0.isEnabled })
  }

  // AppKit applies this to a merely hidden window too, so true would quit the
  // app on every close-button hide; a real close quits via MainFlutterWindow.
  func testHidingTheLastWindowDoesNotQuit() {
    XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
  }

  func testARealCloseTerminatesTheApp() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let terminated = expectation(description: "terminate")
    window.terminate = { terminated.fulfill() }
    window.close()
    wait(for: [terminated], timeout: 2)
  }

  func testHidingTheWindowDoesNotTerminate() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    let notTerminated = expectation(description: "no terminate")
    notTerminated.isInverted = true
    window.terminate = { notTerminated.fulfill() }
    window.orderOut(nil)
    wait(for: [notTerminated], timeout: 0.5)
  }
}
