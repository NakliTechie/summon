import AppKit
import XCTest
@testable import SummonUI
import SummonCore

final class PasteboardRichContentTests: XCTestCase {
    func testOversizedImageIntakeReturnsPromptlyAndDoesNotPersist() throws {
        let core = try SummonCore.inMemory()
        let processed = expectation(description: "background intake finished")
        let threadFlag = ThreadFlag()
        let service = PasteboardService(
            core: core,
            intakeQueue: DispatchQueue(label: "summon.clipboard.intake.test"),
            onProcessed: { accepted in
                XCTAssertFalse(accepted)
                threadFlag.set(Thread.isMainThread)
                processed.fulfill()
            }
        )
        let pasteboard = NSPasteboard.withUniqueName()
        let type = NSPasteboard.PasteboardType("public.png")
        pasteboard.declareTypes([type], owner: nil)
        pasteboard.setData(
            Data(repeating: 0x41, count: ClipboardStore.maximumPayloadBytes + 1),
            forType: type
        )

        let start = Date()
        XCTAssertTrue(service.poll(pasteboard: pasteboard, sourceApp: "Preview"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
        wait(for: [processed], timeout: 5)

        XCTAssertEqual(threadFlag.value, false)
        XCTAssertTrue(try core.clipboard.all().isEmpty)
        XCTAssertTrue(try core.journal.allEntries().isEmpty)
    }

    func testImageExtractionPreservesDeclaredBytes() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let type = NSPasteboard.PasteboardType("public.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        pasteboard.declareTypes([type], owner: nil)
        pasteboard.setData(bytes, forType: type)

        let item = try XCTUnwrap(PasteboardService.item(
            from: pasteboard,
            types: pasteboard.types?.map(\.rawValue) ?? [],
            sourceApp: "Preview"
        ))

        XCTAssertEqual(item.contentKind, .image)
        XCTAssertEqual(item.flavor, "public.png")
        XCTAssertEqual(item.data, bytes)
        XCTAssertEqual(item.sourceApp, "Preview")
    }

    func testFileCopyCapturedAsFileKindAndReCopiesAsFileURL() throws {
        let url = URL(fileURLWithPath: "/private/tmp/summon-file-capture-\(UUID().uuidString).txt")
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))

        let item = try XCTUnwrap(PasteboardService.item(
            from: pasteboard,
            types: pasteboard.types?.map(\.rawValue) ?? [],
            sourceApp: "Finder"
        ))
        XCTAssertEqual(item.contentKind, .file)
        XCTAssertEqual(item.text, url.path)
        XCTAssertEqual(item.flavor, "public.file-url")
        XCTAssertEqual(item.displayText, url.lastPathComponent)

        let out = NSPasteboard.withUniqueName()
        try PasteboardService.writeGeneratedItem(item, asPlainText: false, to: out)
        let outTypes = out.types?.map(\.rawValue) ?? []
        XCTAssertTrue(outTypes.contains("public.file-url"))
        let recovered = try XCTUnwrap(out.readObjects(forClasses: [NSURL.self]) as? [URL])
        XCTAssertEqual(recovered.first?.path, url.path)
    }

    func testFileCopyIngestsGetsAndPurgesEndToEnd() throws {
        let core = try SummonCore.inMemory()
        let path = "/private/tmp/summon-e2e-\(UUID().uuidString).txt"
        let url = URL(fileURLWithPath: path)
        let item = ClipboardItem(
            text: path,
            sourceApp: "Finder",
            contentKind: .file,
            flavor: "public.file-url",
            data: Data(url.absoluteString.utf8)
        )
        XCTAssertNotNil(try core.ingestClipboard(item: item, types: ["public.file-url"], sourceApp: "Finder"))
        XCTAssertTrue(try core.clipboard.all().contains { $0.id == item.id && $0.contentKind == .file })
        let got = try XCTUnwrap(core.clipboard.get(id: item.id))
        XCTAssertEqual(got.contentKind, .file)
        XCTAssertEqual(got.text, path)
        _ = try core.dispatch(action: .clipboardDelete(id: item.id), actor: .user)
        XCTAssertFalse(try core.clipboard.all().contains { $0.id == item.id })
    }

    func testConcealedMarkerSkipsImageBeforeReading() {
        let pasteboard = NSPasteboard.withUniqueName()
        let imageType = NSPasteboard.PasteboardType("public.png")
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([imageType, concealed], owner: nil)
        pasteboard.setData(Data([1, 2, 3]), forType: imageType)

        let item = PasteboardService.item(
            from: pasteboard,
            types: pasteboard.types?.map(\.rawValue) ?? []
        )

        XCTAssertNil(item)
    }

    func testHTMLExtractionRetainsRichBytesAndDeclaredPlainText() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let bytes = Data("<b>Vec&lt;String&gt;</b>".utf8)
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setData(bytes, forType: .html)
        pasteboard.setString("Vec<String>", forType: .string)

        let item = try XCTUnwrap(PasteboardService.item(
            from: pasteboard,
            types: pasteboard.types?.map(\.rawValue) ?? []
        ))

        XCTAssertEqual(item.contentKind, .richText)
        XCTAssertEqual(item.flavor, "public.html")
        XCTAssertEqual(item.text, "Vec<String>")
        XCTAssertEqual(item.data, bytes)
    }

    func testGeneratedImageWritePreservesFlavorAndMarksSelfWrite() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 4, 5, 6])
        let item = ClipboardItem(
            id: "image",
            text: "",
            contentKind: .image,
            flavor: "public.png",
            data: bytes
        )

        try PasteboardService.writeGeneratedItem(item, asPlainText: false, to: pasteboard)

        XCTAssertEqual(pasteboard.data(forType: .init("public.png")), bytes)
        XCTAssertNotNil(pasteboard.data(forType: PasteboardService.generatedType))
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNil(PasteboardService.item(
            from: pasteboard,
            types: pasteboard.types?.map(\.rawValue) ?? []
        ))
    }

    func testRichPlainTextWriteDoesNotReemitMarkup() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let item = ClipboardItem(
            id: "rich",
            text: #"Vec<String> {"ok": true}"#,
            contentKind: .richText,
            flavor: "public.html",
            data: Data("<b>ignored</b>".utf8)
        )

        try PasteboardService.writeGeneratedItem(item, asPlainText: true, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), item.text)
        XCTAssertNil(pasteboard.data(forType: .html))
        XCTAssertNotNil(pasteboard.data(forType: PasteboardService.generatedType))
    }

    func testRichCopyReemitsOriginalHTMLAndPlainFallback() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let html = Data("<b>Hello</b>".utf8)
        let item = ClipboardItem(
            id: "rich-copy",
            text: "Hello",
            contentKind: .richText,
            flavor: "public.html",
            data: html
        )

        try PasteboardService.writeGeneratedItem(item, asPlainText: false, to: pasteboard)

        XCTAssertEqual(pasteboard.data(forType: .html), html)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")
    }

    func testRTFExtractionBuildsPlainFallbackWhenStringTypeIsAbsent() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let rtf = Data(#"{\rtf1\ansi Hello \b world\b0}"#.utf8)
        pasteboard.declareTypes([.rtf], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)

        let item = try XCTUnwrap(PasteboardService.item(
            from: pasteboard,
            types: pasteboard.types?.map(\.rawValue) ?? []
        ))

        XCTAssertEqual(item.contentKind, .richText)
        XCTAssertEqual(item.flavor, "public.rtf")
        XCTAssertTrue(item.text.contains("Hello"))
        XCTAssertTrue(item.text.contains("world"))
    }
}

private final class ThreadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
