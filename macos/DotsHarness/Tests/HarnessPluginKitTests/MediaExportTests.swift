import AppKit
import XCTest
@testable import DotsHarnessCore
@testable import DotsHarnessUI

final class MediaExportTests: XCTestCase {
    @MainActor
    func testCanvasExportsInEveryFormatAtTheRequestedScale() throws {
        let canvas = MediaCanvas(name: "Hero", width: 400, height: 300, backgroundHex: "#FFF4EC", layers: [
            MediaLayer(name: "Blob", kind: .shape, x: 200, y: 30, width: 180, height: 220, colorHex: "#C4A7E7",
                       shape: .ellipse, gradientHex: "#9D7BD8", shadow: 12),
            MediaLayer(name: "Card", kind: .shape, x: 20, y: 200, width: 80, height: 80, colorHex: "#FFFFFF",
                       cornerRadius: 12, strokeHex: "#2B2D6E", strokeWidth: 2, shadow: 8),
            MediaLayer(name: "Paw", kind: .icon, x: 40, y: 220, width: 40, height: 40, colorHex: "#2B2D6E", symbol: "pawprint.fill"),
            MediaLayer(name: "Title", kind: .text, x: 20, y: 40, width: 220, height: 90, text: "Friend for Your Dog",
                       fontSize: 30, alignment: .leading, colorHex: "#2B2D6E", fontDesign: .rounded),
            MediaLayer(name: "Photo", kind: .image, x: 280, y: 200, width: 90, height: 70, colorHex: "#F28B6B",
                       cornerRadius: 10, rotation: 8, prompt: "a happy dog"),
            MediaLayer(name: "Hidden", kind: .shape, x: 0, y: 0, width: 400, height: 300, hidden: true, colorHex: "#000000"),
        ])
        let asset: (String) -> URL = { URL(fileURLWithPath: "/nonexistent/\($0)") }

        let png = try XCTUnwrap(MediaExport.data(of: canvas, format: .png, scale: 2, assetURL: asset))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, 800)
        XCTAssertEqual(bitmap.pixelsHigh, 600)
        // The hidden black layer covers everything; a light corner proves it was left out.
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)).redComponent, 0.9)

        let jpeg = try XCTUnwrap(MediaExport.data(of: canvas, format: .jpeg, scale: 1, assetURL: asset))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        let pdf = try XCTUnwrap(MediaExport.data(of: canvas, format: .pdf, scale: 1, assetURL: asset))
        XCTAssertEqual(String(decoding: pdf.prefix(4), as: UTF8.self), "%PDF")

        let layer = try XCTUnwrap(MediaExport.data(of: canvas.layers[1], format: .png, scale: 1, assetURL: asset))
        XCTAssertEqual(NSBitmapImageRep(data: layer)?.pixelsWide, 80)
    }
}
