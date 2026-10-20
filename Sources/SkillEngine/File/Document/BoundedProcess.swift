import Foundation

/// 다른 프로그램(unzip 등)을 돌려 결과를 받되, 정한 양을 넘으면 멈추고 버린다.
/// 작은 파일이 풀면 수십 GB가 되는 "압축 폭탄"이 메모리를 다 먹지 못하게 한다.
enum BoundedProcess {
    /// 한 번에 받아들이는 결과 상한(64MB). 글만 꺼내는 데는 넉넉하다.
    static let defaultLimit = 64 * 1024 * 1024

    static func run(_ executable: String, _ arguments: [String], limit: Int = defaultLimit) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let reader = pipe.fileHandleForReading
        var data = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > limit {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// unzip 결과를 글로(상한을 넘거나 실패하면 nil)
    static func unzip(_ arguments: [String]) -> String? {
        run("/usr/bin/unzip", arguments).map { String(decoding: $0, as: UTF8.self) }
    }
}
