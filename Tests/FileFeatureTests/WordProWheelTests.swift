import Testing
@testable import FileFeature

/// 도구 휠: WordPro가 여는 문서 형식이면 WordPro 칸이 나온다
struct WordProWheelTests {
    @Test(arguments: ["docx", "hwpx", "epub", "odt", "md"])
    func documentShowsWordPro(_ ext: String) {
        let layout = WheelLayout.tools(forDraggedFileExtensions: [ext])
        #expect(layout.slots.compactMap { $0 }.contains { $0.id == "pdf-addon" })
    }
}
