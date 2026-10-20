import Compression
import Foundation

/// .docx 같은 zip 묶음을 만든다(외부 프로그램 없이). 압축은 DEFLATE, 압축해도 안 줄면 그대로 담는다.
/// 파일 이름은 UTF-8로 표시한다.
struct ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let method: UInt16       // 0 = 그대로, 8 = DEFLATE
        let compressedSize: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var output = Data()
    private var entries: [Entry] = []
    private let time: UInt16
    private let date: UInt16

    init(date: Date = Date()) {
        // zip은 MS-DOS 방식 날짜·시간(2초 단위)을 쓴다
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let packedTime: Int = (hour << 11) | (minute << 5) | (second / 2)
        let packedDate: Int = (year << 9) | (month << 5) | day
        time = UInt16(truncatingIfNeeded: packedTime)
        self.date = UInt16(truncatingIfNeeded: packedDate)
    }

    /// `store`: 압축하지 않고 그대로 넣는다(EPUB의 mimetype처럼 꼭 그래야 하는 파일)
    mutating func add(_ path: String, _ contents: Data, store: Bool = false) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(contents)
        let deflated = store ? nil : Self.deflate(contents)
        let useDeflate = deflated.map { $0.count < contents.count } ?? false
        let body = useDeflate ? deflated! : contents
        let entry = Entry(name: name, crc: crc, method: useDeflate ? 8 : 0,
                          compressedSize: UInt32(body.count), size: UInt32(contents.count), offset: UInt32(output.count))
        // 로컬 파일 머리
        output.append(le32: 0x0403_4b50)
        output.append(le16: 20)
        output.append(le16: 0x0800)
        output.append(le16: entry.method)
        output.append(le16: time)
        output.append(le16: date)
        output.append(le32: crc)
        output.append(le32: entry.compressedSize)
        output.append(le32: entry.size)
        output.append(le16: UInt16(name.count))
        output.append(le16: 0)
        output.append(name)
        output.append(body)
        entries.append(entry)
    }

    mutating func add(_ path: String, _ text: String) { add(path, Data(text.utf8)) }

    /// 중앙 목록과 끝 표시를 붙여서 완성된 zip을 돌려준다
    func finish() -> Data {
        var data = output
        let directoryStart = UInt32(data.count)
        for entry in entries {
            data.append(le32: 0x0201_4b50)
            data.append(le16: 20)
            data.append(le16: 20)
            data.append(le16: 0x0800)
            data.append(le16: entry.method)
            data.append(le16: time)
            data.append(le16: date)
            data.append(le32: entry.crc)
            data.append(le32: entry.compressedSize)
            data.append(le32: entry.size)
            data.append(le16: UInt16(entry.name.count))
            data.append(le16: 0)
            data.append(le16: 0)
            data.append(le16: 0)
            data.append(le16: 0)
            data.append(le32: 0)
            data.append(le32: entry.offset)
            data.append(entry.name)
        }
        let directorySize = UInt32(data.count) - directoryStart
        data.append(le32: 0x0605_4b50)
        data.append(le16: 0)
        data.append(le16: 0)
        data.append(le16: UInt16(entries.count))
        data.append(le16: UInt16(entries.count))
        data.append(le32: directorySize)
        data.append(le32: directoryStart)
        data.append(le16: 0)
        return data
    }

    /// Apple Compression의 ZLIB은 머리 없는 순수 DEFLATE라 zip에 그대로 넣을 수 있다
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
