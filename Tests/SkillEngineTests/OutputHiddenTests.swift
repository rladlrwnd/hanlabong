import Foundation
import Testing
@testable import SkillEngine

/// NAS(SMB)에서 결과 파일에 숨김 표시가 남아 Finder에 안 보이던 문제
struct OutputHiddenTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hanlabong-hidden-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func savedResultIsNotHidden() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: original)
        let out = try FileOutputWriter.save(Data([4, 5]), fileExtension: "jpg", suffix: "_web", besideOriginal: original)
        #expect(out.lastPathComponent == "photo_web.jpg")
        #expect(try out.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
    }

    /// SMB처럼 숨김이 붙어 있어도 풀린다(로컬에서는 숨김 표시를 직접 붙여서 흉내 낸다)
    @Test func unhideClearsHiddenFlag() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var file = dir.appendingPathComponent("photo_web.jpg")
        try Data([1]).write(to: file)
        var hide = URLResourceValues()
        hide.isHidden = true
        try file.setResourceValues(hide)
        file.removeAllCachedResourceValues()
        #expect(try file.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
        FileOutputWriter.unhide(file)
        file.removeAllCachedResourceValues()
        #expect(try file.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
    }
}
