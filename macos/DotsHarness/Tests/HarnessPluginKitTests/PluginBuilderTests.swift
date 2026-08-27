// Copyright (c) 2026 DOTS
// PluginBuilder dylib-location logic (no toolchain needed).

import XCTest
@testable import DotsHarnessCore

final class PluginBuilderTests: XCTestCase {
    func testLocateDylibByExactThenLibPrefixThenSole() throws {
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }

        // sole dylib, unusual name
        let sole = bin.appendingPathComponent("weird.dylib")
        try Data().write(to: sole)
        XCTAssertEqual(try PluginBuilder.locateDylib(in: bin, preferred: "libThing.dylib").lastPathComponent, "weird.dylib")

        // libThing.dylib present -> matched from stem
        let libThing = bin.appendingPathComponent("libThing.dylib")
        try Data().write(to: libThing)
        XCTAssertEqual(try PluginBuilder.locateDylib(in: bin, preferred: "Thing.dylib").lastPathComponent, "libThing.dylib")

        // exact name wins
        let exact = bin.appendingPathComponent("Thing.dylib")
        try Data().write(to: exact)
        XCTAssertEqual(try PluginBuilder.locateDylib(in: bin, preferred: "Thing.dylib").lastPathComponent, "Thing.dylib")
    }
}
