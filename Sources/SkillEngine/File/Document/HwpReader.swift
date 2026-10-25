import Compression
import Foundation

/// 옛 한글 파일(.hwp, 한글 97 이후의 HWP 5.0) 글자 읽기.
///
/// .hwp는 zip(.hwpx)이 아니라 MS 옛 오피스와 같은 "복합 파일"(OLE) 상자 안에 여러 칸(스트림)이 든 구조다.
/// - FileHeader 칸: 압축 여부, 암호, 배포용 문서인지
/// - BodyText/Section0, Section1, …: 본문. 보통 deflate로 압축돼 있고, 풀면 "레코드"가 줄줄이 나온다
/// - 레코드 중 문단 글자(HWPTAG_PARA_TEXT)만 골라 UTF-16 글자로 읽는다. 표 안 글자도 문단이라 같이 나온다.
/// 모양(글꼴·표 테두리)은 버리고 문단 글자만 꺼낸다(.hwpx 읽기와 같은 수준).
enum HwpReader {
    enum Failure: Error { case notHwp, locked, distribution, broken }

    /// 풀린 본문이 이보다 커지면 거절(압축 폭탄 막기, 다른 문서 읽기와 같은 64MB)
    static let maxInflatedBytes = 64_000_000

    static func paragraphs(_ url: URL) throws -> [String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Failure.broken }
        let box = try CompoundFile(data)
        guard let header = box.stream("FileHeader"), header.count >= 40,
              header.starts(with: Array("HWP Document File".utf8)) else { throw Failure.notHwp }
        let flags = header.uint32(at: 36)
        if flags & 0b10 != 0 { throw Failure.locked }          // 암호
        if flags & 0b100 != 0 { throw Failure.distribution }   // 배포용(본문이 따로 잠겨 있다)
        let compressed = flags & 0b1 != 0

        var result: [String] = []
        var inflatedTotal = 0
        for index in 0..<1000 {
            guard let raw = box.stream("BodyText/Section\(index)") else { break }
            let section = compressed ? try inflate(raw, limit: maxInflatedBytes - inflatedTotal) : raw
            inflatedTotal += section.count
            result += texts(inRecords: section)
        }
        guard !result.isEmpty else { throw Failure.broken }
        return result
    }

    /// 레코드 머리(4바이트): 아래 10비트 = 종류, 위 12비트 = 길이(0xFFF면 다음 4바이트가 진짜 길이)
    static func texts(inRecords data: Data) -> [String] {
        let paraText: UInt32 = 0x10 + 51
        var out: [String] = []
        var offset = 0
        while offset + 4 <= data.count {
            let head = data.uint32(at: offset)
            offset += 4
            var size = Int(head >> 20)
            if size == 0xFFF {
                guard offset + 4 <= data.count else { break }
                size = Int(data.uint32(at: offset))
                offset += 4
            }
            guard size >= 0, offset + size <= data.count else { break }
            if head & 0x3FF == paraText {
                let text = paragraphText(data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + size))
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
            }
            offset += size
        }
        return out
    }

    /// 문단 글자: UTF-16. 32보다 작은 값은 조종 문자라 크기가 다르다.
    /// - 글자 하나짜리: 0, 10(줄바꿈), 13(문단 끝), 24~31(하이픈·묶음 빈칸·고정폭 빈칸 등)
    /// - 나머지(표·그림·각주 자리 등)는 8글자(16바이트)를 차지하고 글자는 아니다
    static func paragraphText(_ data: Data) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var i = 0
        let count = data.count / 2
        while i < count {
            let c = data.uint16(at: i * 2)
            if c >= 32 { units.append(c); i += 1; continue }
            switch c {
            case 10: units.append(0x0A)
            case 24: units.append(0x2D)                  // 하이픈
            case 30, 31: units.append(0x20)              // 묶음 빈칸·고정폭 빈칸
            case 0, 13, 25...29: break
            default: i += 8; continue
            }
            i += 1
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// deflate(앞머리 없는 raw) 풀기. limit을 넘으면 멈추고 거절.
    static func inflate(_ data: Data, limit: Int) throws -> Data {
        guard limit > 0 else { throw Failure.broken }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw Failure.broken }
        defer { compression_stream_destroy(&stream) }
        let chunk = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { throw Failure.broken }
            stream.src_ptr = base
            stream.src_size = source.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: chunk - stream.dst_size)
                if output.count > limit { throw Failure.broken }
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw Failure.broken }
                if stream.src_size == 0 && stream.dst_size == chunk { break }   // 더 나올 게 없음(끝 표시 없이 끝난 압축)
            }
        }
        return output
    }
}

/// MS 복합 파일(Compound File Binary, OLE2) 읽기: 512바이트 머리 → 섹터 지도(FAT) → 목록 → 칸(스트림).
/// 망가진 파일에서 무한히 돌지 않게 사슬 길이와 범위를 매번 확인한다.
struct CompoundFile {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let miniStream: Data
    private var streams: [String: (start: UInt32, size: Int)] = [:]

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let free: UInt32 = 0xFFFF_FFFF

    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 512, data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else { throw HwpReader.Failure.notHwp }
        let sectorShift = Int(data.uint16(at: 0x1E)), miniShift = Int(data.uint16(at: 0x20))
        guard (9...12).contains(sectorShift), (6...6).contains(miniShift) else { throw HwpReader.Failure.broken }
        sectorSize = 1 << sectorShift
        miniSectorSize = 1 << miniShift
        miniCutoff = Int(data.uint32(at: 0x38))
        let fatCount = Int(data.uint32(at: 0x2C))
        let firstDir = data.uint32(at: 0x30)
        let firstMiniFat = data.uint32(at: 0x3C)
        var difatNext = data.uint32(at: 0x44)
        let maxSectors = data.count / sectorSize + 1
        guard fatCount <= maxSectors else { throw HwpReader.Failure.broken }

        // FAT 섹터 번호: 머리에 109개, 넘치면 DIFAT 섹터 사슬에 이어서
        var fatSectors: [UInt32] = (0..<109).map { data.uint32(at: 0x4C + $0 * 4) }.filter { $0 < 0xFFFF_FFFA }
        var guardCount = 0
        while difatNext < 0xFFFF_FFFA, fatSectors.count < fatCount, guardCount < maxSectors {
            let base = (Int(difatNext) + 1) * sectorSize
            guard base + sectorSize <= data.count else { throw HwpReader.Failure.broken }
            let perSector = sectorSize / 4 - 1
            fatSectors += (0..<perSector).map { data.uint32(at: base + $0 * 4) }.filter { $0 < 0xFFFF_FFFA }
            difatNext = data.uint32(at: base + perSector * 4)
            guardCount += 1
        }
        var fat: [UInt32] = []
        for sector in fatSectors.prefix(fatCount) {
            let base = (Int(sector) + 1) * sectorSize
            guard base + sectorSize <= data.count else { throw HwpReader.Failure.broken }
            fat += (0..<(sectorSize / 4)).map { data.uint32(at: base + $0 * 4) }
        }
        self.fat = fat

        let directory = try Self.chain(data, fat: fat, start: firstDir, sectorSize: sectorSize, limit: data.count)
        let miniFatBytes = firstMiniFat < 0xFFFF_FFFA ? try Self.chain(data, fat: fat, start: firstMiniFat, sectorSize: sectorSize, limit: data.count) : Data()
        miniFat = (0..<(miniFatBytes.count / 4)).map { miniFatBytes.uint32(at: $0 * 4) }

        // 목록: 128바이트씩. 이름(UTF-16), 종류(1 폴더·2 칸·5 뿌리), 왼쪽·오른쪽 형제, 첫 자식, 시작 섹터, 크기
        struct Entry { let name: String; let type: UInt8; let left, right, child, start: UInt32; let size: Int }
        var entries: [Entry] = []
        for index in 0..<(directory.count / 128) {
            let base = index * 128
            let nameBytes = min(Int(directory.uint16(at: base + 0x40)), 64)
            let nameUnits = (0..<max(nameBytes / 2 - 1, 0)).map { directory.uint16(at: base + $0 * 2) }
            entries.append(Entry(name: String(decoding: nameUnits, as: UTF16.self), type: directory[directory.startIndex + base + 0x42],
                                 left: directory.uint32(at: base + 0x44), right: directory.uint32(at: base + 0x48),
                                 child: directory.uint32(at: base + 0x4C), start: directory.uint32(at: base + 0x74),
                                 size: Int(directory.uint32(at: base + 0x78))))
        }
        guard let root = entries.first, root.type == 5 else { throw HwpReader.Failure.broken }
        miniStream = root.start < 0xFFFF_FFFA ? try Self.chain(data, fat: fat, start: root.start, sectorSize: sectorSize, limit: root.size) : Data()

        // 폴더 안은 이진 나무(왼쪽·오른쪽 형제)로 엮여 있다. 경로 "BodyText/Section0"로 펼쳐 둔다
        var visited = Set<UInt32>()
        func walk(_ id: UInt32, prefix: String) {
            guard id < entries.count, visited.insert(id).inserted else { return }
            let entry = entries[Int(id)]
            walk(entry.left, prefix: prefix)
            walk(entry.right, prefix: prefix)
            let path = prefix.isEmpty ? entry.name : prefix + "/" + entry.name
            if entry.type == 2 { streams[path] = (entry.start, entry.size) }
            if entry.type == 1 { walk(entry.child, prefix: path) }
        }
        walk(root.child, prefix: "")
    }

    func stream(_ path: String) -> Data? {
        guard let (start, size) = streams[path], size <= data.count else { return nil }
        if size < miniCutoff {
            var out = Data()
            var sector = start, steps = 0
            while sector < 0xFFFF_FFFA, out.count < size, steps <= miniFat.count {
                let base = Int(sector) * miniSectorSize
                guard base + miniSectorSize <= miniStream.count, Int(sector) < miniFat.count else { return nil }
                out.append(miniStream.subdata(in: miniStream.startIndex + base ..< miniStream.startIndex + base + miniSectorSize))
                sector = miniFat[Int(sector)]
                steps += 1
            }
            return out.count >= size ? out.prefix(size) : nil
        }
        guard let out = try? Self.chain(data, fat: fat, start: start, sectorSize: sectorSize, limit: size), out.count >= size else { return nil }
        return out.prefix(size)
    }

    /// 섹터 사슬을 따라 이어 붙인다(limit 바이트까지, 고리가 있으면 거절)
    private static func chain(_ data: Data, fat: [UInt32], start: UInt32, sectorSize: Int, limit: Int) throws -> Data {
        var out = Data()
        var sector = start, steps = 0
        while sector < 0xFFFF_FFFA, out.count < limit {
            let base = (Int(sector) + 1) * sectorSize
            guard base + sectorSize <= data.count, Int(sector) < fat.count, steps <= fat.count else { throw HwpReader.Failure.broken }
            out.append(data.subdata(in: data.startIndex + base ..< data.startIndex + base + sectorSize))
            sector = fat[Int(sector)]
            steps += 1
        }
        return out
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
    func uint32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
