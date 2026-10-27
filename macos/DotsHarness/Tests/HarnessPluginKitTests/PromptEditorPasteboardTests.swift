import AppKit
import XCTest
@testable import DotsHarnessUI

final class PromptEditorPasteboardTests: XCTestCase {
    @MainActor
    func testPNGDataPasteboardRepresentationBecomesPNG() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let png = try makePNGData()
        let type = NSPasteboard.PasteboardType("public.png")
        pasteboard.declareTypes([type], owner: nil)
        XCTAssertTrue(pasteboard.setData(png, forType: type))

        let pastedData = try XCTUnwrap(PromptNSTextView.pngImageData(from: pasteboard))
        XCTAssertNotNil(NSBitmapImageRep(data: pastedData))
    }

    @MainActor
    func testCopiedImageFileURLBecomesPNG() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        try makePNGData().write(to: imageURL)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([imageURL as NSURL]))

        let pastedData = try XCTUnwrap(PromptNSTextView.pngImageData(from: pasteboard))
        XCTAssertNotNil(NSBitmapImageRep(data: pastedData))
    }

    @MainActor
    func testSameEditorAcceptsConsecutiveImagePastes() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let imageType = NSPasteboard.PasteboardType("public.png")
        let view = PromptNSTextView()
        var pastedImages: [Data] = []
        view.onPasteImage = { pastedImages.append($0) }

        for _ in 0..<2 {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setData(try makePNGData(), forType: imageType))
            XCTAssertTrue(view.pasteImage(from: pasteboard))
        }

        XCTAssertEqual(pastedImages.count, 2)
    }

    @MainActor
    func testTextPasteboardIsNotTreatedAsImage() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("ordinary text", forType: .string)

        XCTAssertNil(PromptNSTextView.pngImageData(from: pasteboard))
    }

    @MainActor
    private func makePNGData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
