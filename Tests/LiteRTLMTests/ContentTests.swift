import XCTest
@testable import LiteRTLM

final class ContentTests: XCTestCase {

    // MARK: - Contents factory methods

    func testContentsOfText() {
        let contents = Contents.of("Hello")
        XCTAssertEqual(contents.items.count, 1)
        if case .text(let t) = contents.items[0] { XCTAssertEqual(t, "Hello") }
        else { XCTFail("Expected .text") }
    }

    func testContentsOfVariadic() {
        let data = Data([0xFF, 0xD8])
        let contents = Contents.of(.text("prompt"), .imageBytes(data))
        XCTAssertEqual(contents.items.count, 2)
    }

    func testContentsOfArray() {
        let items: [Content] = [.text("a"), .text("b")]
        let contents = Contents.of(items)
        XCTAssertEqual(contents.items.count, 2)
    }

    func testContentsEmpty() {
        let contents = Contents.empty()
        XCTAssertTrue(contents.items.isEmpty)
    }

    func testContentsDescription() {
        let contents = Contents.of(.text("Hello"), .imageBytes(Data()), .text(" World"))
        // description joins only text items
        XCTAssertEqual(contents.description, "Hello World")
    }

    func testContentsDescriptionNoText() {
        let contents = Contents.of(.imageBytes(Data([1, 2, 3])))
        XCTAssertEqual(contents.description, "")
    }

    // MARK: - Content cases

    func testContentTextDescription() {
        let content = Content.text("hello")
        XCTAssertEqual(content.description, "hello")
    }

    func testContentImageBytesDescription() {
        let content = Content.imageBytes(Data([0xFF]))
        XCTAssertEqual(content.description, "")
    }

    func testContentAudioBytesDescription() {
        let content = Content.audioBytes(Data([0x00]))
        XCTAssertEqual(content.description, "")
    }

    func testContentToolResponse() {
        let content = Content.toolResponse(name: "weather", response: "{\"temp\": 28}")
        XCTAssertEqual(content.description, "")
    }

    func testContentImageFile() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let content = Content.imageFile(url)
        if case .imageFile(let u) = content { XCTAssertEqual(u.path, "/tmp/photo.jpg") }
        else { XCTFail("Expected .imageFile") }
    }

    func testContentAudioFile() {
        let url = URL(fileURLWithPath: "/tmp/audio.wav")
        let content = Content.audioFile(url)
        if case .audioFile(let u) = content { XCTAssertEqual(u.path, "/tmp/audio.wav") }
        else { XCTFail("Expected .audioFile") }
    }
}
