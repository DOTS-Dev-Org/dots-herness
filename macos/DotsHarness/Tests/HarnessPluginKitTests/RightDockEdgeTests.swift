// Copyright (c) 2026 DOTS

import XCTest
@testable import DotsHarnessUI
import DotsHarnessCore

final class RightDockEdgeTests: XCTestCase {
    func testOuterQuarterPicksItsEdgeAndCentreDoesNotMove() {
        let area = CGSize(width: 1000, height: 800)

        XCTAssertNil(dockEdge(at: CGPoint(x: 500, y: 400), in: area, rightToLeft: false))
        XCTAssertEqual(dockEdge(at: CGPoint(x: 50, y: 400), in: area, rightToLeft: false), .leading)
        XCTAssertEqual(dockEdge(at: CGPoint(x: 950, y: 400), in: area, rightToLeft: false), .trailing)
        XCTAssertEqual(dockEdge(at: CGPoint(x: 500, y: 50), in: area, rightToLeft: false), .top)
        XCTAssertEqual(dockEdge(at: CGPoint(x: 500, y: 750), in: area, rightToLeft: false), .bottom)
        // Dragged over the sidebar still counts as leading.
        XCTAssertEqual(dockEdge(at: CGPoint(x: -40, y: 400), in: area, rightToLeft: false), .leading)
        // RTL: leading is the physical right, next to the sidebar.
        XCTAssertEqual(dockEdge(at: CGPoint(x: 950, y: 400), in: area, rightToLeft: true), .leading)
    }

    @MainActor
    func testMovedToolReopensOnItsRememberedEdge() {
        let previous = UserDefaults.standard.object(forKey: "dock.edge.files")
        let browserEdge = UserDefaults.standard.object(forKey: "dock.edge.browser")
        UserDefaults.standard.removeObject(forKey: "dock.edge.files")
        UserDefaults.standard.removeObject(forKey: "dock.edge.browser")
        defer {
            UserDefaults.standard.set(previous, forKey: "dock.edge.files")
            UserDefaults.standard.set(browserEdge, forKey: "dock.edge.browser")
        }
        let dock = RightDockState()
        dock.projectName = "demo"
        dock.add(.files, unique: true)
        dock.add(.browser, unique: false)
        dock.add(.browser, unique: false)
        XCTAssertEqual(dock.tabs.map(\.number), [1, 1, 2])
        XCTAssertTrue(dock.tabs[0].title.contains("demo"))
        XCTAssertEqual(dock.tabs[0].edge, .trailing)
        dock.move(dock.tabs[0], to: .bottom)
        XCTAssertEqual(dock.selected[.bottom], dock.tabs[0].id)

        let reopened = RightDockState()
        reopened.add(.files, unique: true)
        XCTAssertEqual(reopened.tabs.last?.edge, .bottom)
        // A moved tool does not pop the right dock open.
        XCTAssertFalse(reopened.isVisible)
    }
    @MainActor
    func testBrowserTabsOwnIndependentHistoryAndAgentSelectsItsOwnTab() {
        let dock = RightDockState()
        dock.add(.browser, unique: false, at: .trailing)
        dock.add(.browser, unique: false, at: .trailing)
        let first = dock.browser(for: dock.tabs[0])!
        let second = dock.browser(for: dock.tabs[1])!
        XCTAssertFalse(first === second)
        XCTAssertFalse(first.webView === second.webView)
        first.currentURLString = "https://example.com/first"
        second.currentURLString = "https://example.org/second"
        dock.select(dock.tabs[0])
        XCTAssertEqual(second.currentURLString, "https://example.org/second")
        XCTAssertTrue(NativeBrowserService.shared === first)
        dock.showBrowser()
        XCTAssertEqual(dock.selected[.trailing], dock.tabs[0].id)
        dock.select(dock.tabs[1])
        XCTAssertTrue(NativeBrowserService.shared === second)
        dock.showBrowser()
        XCTAssertEqual(dock.selected[.trailing], dock.tabs[1].id)
        XCTAssertEqual(dock.tabs.count, 2)
    }

    @MainActor
    func testOmniboxSearchAddressAndLocalPreviewResolution() {
        XCTAssertEqual(NativeBrowserService.addressURL(for: "example.com/docs")?.absoluteString, "https://example.com/docs")
        XCTAssertEqual(NativeBrowserService.addressURL(for: "localhost:3000/test")?.absoluteString, "http://localhost:3000/test")
        XCTAssertEqual(NativeBrowserService.addressURL(for: "127.0.0.1:8080")?.scheme, "http")
        XCTAssertEqual(NativeBrowserService.addressURL(for: "[::1]:3000")?.scheme, "http")
        let search = NativeBrowserService.addressURL(for: "  Türkçe arama & test  ")!
        XCTAssertEqual(search.host, "www.google.com")
        XCTAssertEqual(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Türkçe arama & test")
        XCTAssertEqual(NativeBrowserService.addressURL(for: "google")?.path, "/search")
        XCTAssertNil(NativeBrowserService.addressURL(for: "  "))
        XCTAssertNil(NativeBrowserService.addressURL(for: "javascript:alert(1)"))
        XCTAssertNil(NativeBrowserService.addressURL(for: "file:///etc/passwd"))
        XCTAssertNil(NativeBrowserService.addressURL(for: "data:text/html,test"))
    }

    @MainActor
    func testSplitKeepsTwoPanesAndSelectedTabsVisible() {
        let split = UserDefaults.standard.object(forKey: "dock.split")
        let horizontal = UserDefaults.standard.object(forKey: "dock.horizontalSplits")
        defer {
            UserDefaults.standard.set(split, forKey: "dock.split")
            UserDefaults.standard.set(horizontal, forKey: "dock.horizontalSplits")
        }
        let dock = RightDockState()
        for _ in 0..<3 { dock.add(.browser, unique: false, at: .trailing) }
        dock.setSplit(.trailing, horizontal: true)
        XCTAssertEqual(dock.splitTabs(on: .trailing).map(\.id), [dock.tabs[0].id, dock.tabs[2].id])
        dock.select(dock.tabs[0])
        dock.select(dock.tabs[1])
        XCTAssertEqual(dock.splitTabs(on: .trailing).map(\.id), [dock.tabs[1].id, dock.tabs[2].id])
        XCTAssertEqual(dock.minimumWidth(on: .trailing), 401)
        dock.setSplit(.trailing, horizontal: false)
        XCTAssertEqual(dock.minimumWidth(on: .trailing), 240)
        XCTAssertEqual(dock.minimumHeight(on: .trailing), 245)
        dock.setSplit(.trailing, horizontal: nil)
        XCTAssertFalse(dock.split.contains(.trailing))
    }

}
