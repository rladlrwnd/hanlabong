import Foundation

/// 맥 기본 영상 엔진(AVFoundation)이 못 읽는 영상(AVI·MKV·WMV·FLV·WebM 등)은 설치된 ffmpeg로 바꾼다.
/// ffmpeg는 앱에 넣지 않고, 이 맥에 깔려 있는 것(Homebrew 등)을 찾아 쓴다. 파일은 이 컴퓨터 밖으로 안 나간다.
public enum FFmpeg {
    /// AVFoundation이 못 여는 영상 확장자
    public static let foreignVideoExtensions: Set<String> = ["avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "mts", "3gp", "ogv", "divx", "vob", "gif"]

    public static func needsFFmpeg(_ url: URL) -> Bool { foreignVideoExtensions.contains(url.pathExtension.lowercased()) }

    /// 정해진 설치 위치에서만 찾는다(PATH를 뒤지면 아무 폴더에 놓인 가짜 ffmpeg가 실행될 수 있다)
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    /// 입력 파일 안전장치. ffmpeg는 "재생목록" 같은 형식을 받으면 그 안에 적힌 인터넷 주소나 다른 파일을 따라가 읽는다.
    /// 그래서 (1) 이 컴퓨터의 파일만 열고(protocol), (2) 진짜 영상 담는 형식만 받는다(format — 재생목록·이어붙이기 목록은 거절).
    static let inputGuard = ["-protocol_whitelist", "file",
                             "-format_whitelist", "mov,avi,matroska,webm,asf,flv,mpeg,mpegts,mpegvideo,gif,ogg,mp3"]

    /// 파일 앞부분이 진짜 영상(또는 움직이는 GIF)인지. 이름만 영상인 글 파일(재생목록 등)은 여기서 걸러진다.
    public static func isRealVideo(_ url: URL) -> Bool {
        switch FileKindDetector.kind(of: url) {
        case .video?: return true
        case .image?: return url.pathExtension.lowercased() == "gif"
        default: return false
        }
    }

    /// 소리 파일(M4A·MP3) 앞부분 표시 — 변환 결과를 확인할 때 쓴다
    static func isRealAudio(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 12)) ?? Data()
        guard head.count >= 4 else { return false }
        if head.count >= 8, String(decoding: head[4..<8], as: UTF8.self) == "ftyp" { return true }          // M4A
        if head.starts(with: Array("ID3".utf8)) { return true }                                             // MP3(태그)
        return head[0] == 0xFF && (head[1] & 0xE0) == 0xE0                                                 // MP3(프레임)
    }

    private static func find(_ name: String) -> URL? {
        for dir in searchPaths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static var executable: URL? { find("ffmpeg") }
    public static var probeExecutable: URL? { find("ffprobe") }

    public struct Info: Sendable, Equatable {
        public var duration: Double
        public var hasVideo: Bool
        public var hasAudio: Bool
    }

    /// 영상 길이와 소리·영상 트랙이 있는지
    public static func probe(_ url: URL) throws -> Info {
        guard let ffprobe = probeExecutable else { throw FileSkillError.exportFailed(missingMessage) }
        guard isRealVideo(url) || isRealAudio(url) else { throw FileSkillError.noVideoTrack(url.lastPathComponent) }
        let out = try run(ffprobe, ["-v", "error"] + inputGuard + ["-show_entries", "stream=codec_type:format=duration", "-of", "default=noprint_wrappers=1", url.path],
                          cancellation: FileCancellation())
        var info = Info(duration: 0, hasVideo: false, hasAudio: false)
        for line in out.split(separator: "\n") {
            if line == "codec_type=video" { info.hasVideo = true }
            if line == "codec_type=audio" { info.hasAudio = true }
            if line.hasPrefix("duration="), let d = Double(line.dropFirst("duration=".count)) { info.duration = d }
        }
        return info
    }

    static let missingMessage = L("이 영상(AVI·MKV 등)은 ffmpeg가 있어야 바꿀 수 있어요 · 터미널에서 brew install ffmpeg", "This video (AVI, MKV…) needs ffmpeg · run brew install ffmpeg in Terminal")

    /// 변환 인자. 해상도는 비율을 지키며 그 크기 안으로 줄이기만 한다(작은 영상을 키우지 않음).
    static func arguments(_ spec: VideoSpec, input: URL, output: URL, start: Double?, end: Double?) -> [String] {
        let format = spec.resolvedFormat(input: input)
        var args = ["-nostdin", "-y", "-hide_banner", "-loglevel", "error"]
        if let start, start > 0 { args += ["-ss", String(format: "%.3f", start)] }
        args += inputGuard + ["-i", input.path]
        if let end { args += ["-t", String(format: "%.3f", end - (start ?? 0))] }
        let box: (Int, Int)? = {
            switch spec.preset {
            case .p1080, .hevc1080: return (1920, 1080)
            case .p720: return (1280, 720)
            case .p480: return (854, 480)
            case .passthrough, .audioOnly: return nil
            }
        }()
        func scale(_ fallback: (Int, Int)? = nil) -> String {
            guard let (w, h) = box ?? fallback else { return "scale=trunc(iw/2)*2:trunc(ih/2)*2" }
            return "scale=w='min(\(w),iw)':h='min(\(h),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
        }
        // 소리만
        if format == .mp3 { return args + ["-vn", "-c:a", "libmp3lame", "-q:a", "2", output.path] }
        if format == .m4a || spec.preset == .audioOnly { return args + ["-vn", "-c:a", "aac", "-b:a", "192k", output.path] }
        // 움직이는 GIF: 초당 12장, 긴 변 640 이하, 색을 영상에 맞춰 고른다
        if format == .gif {
            let size = box.map { "\(min($0.0, 640))" } ?? "640"
            return args + ["-vf", "fps=12,scale='min(\(size),iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                           "-loop", "0", "-an", output.path]
        }
        let audio: [String]
        switch format {
        case .webm:
            args += ["-vf", scale(), "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
            audio = ["-c:a", "libopus", "-b:a", "128k"]
        case .avi:
            args += ["-vf", scale(), "-c:v", "mpeg4", "-q:v", "3", "-vtag", "xvid"]
            audio = ["-c:a", "libmp3lame", "-q:a", "3"]
        case .wmv:
            args += ["-vf", scale(), "-c:v", "wmv2", "-q:v", "3"]
            audio = ["-c:a", "wmav2", "-b:a", "160k"]
        default:   // mp4·mov·mkv: H.264(HEVC 프리셋이면 H.265) + AAC
            if spec.preset == .hevc1080 {
                args += ["-vf", scale(), "-c:v", "libx265", "-preset", "medium", "-crf", "26", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
            } else {
                let crf: String = { switch spec.preset { case .passthrough: return "18"; case .p1080: return "20"; case .p720: return "22"; default: return "24" } }()
                args += ["-vf", scale(), "-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-crf", crf]
            }
            audio = ["-c:a", "aac", "-b:a", "160k"]
        }
        args += spec.muted ? ["-an"] : audio
        if format == .mp4 || format == .mov { args += ["-movflags", "+faststart"] }
        return args + [output.path]
    }

    /// 영상을 바꾼다. 취소하면 ffmpeg를 멈추고 만들던 파일을 지운다.
    public static func convert(_ spec: VideoSpec, input: URL, to output: URL, cancellation: FileCancellation) throws {
        guard let ffmpeg = executable else { throw FileSkillError.exportFailed(missingMessage) }
        let name = input.lastPathComponent
        let info = try probe(input)
        if spec.preset == .audioOnly || spec.resolvedFormat(input: input).isAudio { guard info.hasAudio else { throw FileSkillError.noAudio(name) } }
        else { guard info.hasVideo else { throw FileSkillError.noVideoTrack(name) } }
        let total = info.duration
        var start = spec.trimStart.map { max(0, $0) }
        var end = spec.trimEnd
        if total > 0 {
            if let s = start { start = min(s, max(total - 0.1, 0)) }
            if let e = end { end = min(max(e, (start ?? 0) + 0.1), total) }
        }
        do {
            _ = try run(ffmpeg, arguments(spec, input: input, output: output, start: start, end: end), cancellation: cancellation)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// 프로그램을 돌리고 표준 출력을 돌려준다. 실패하면 오류 출력 마지막 줄을 알려준다.
    private static func run(_ executable: URL, _ arguments: [String], cancellation: FileCancellation) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let collected = OutputBox()
        out.fileHandleForReading.readabilityHandler = { collected.append(out: $0.availableData) }
        err.fileHandleForReading.readabilityHandler = { collected.append(err: $0.availableData) }
        try process.run()
        while process.isRunning {
            if cancellation.isCancelled {
                process.terminate()
                process.waitUntilExit()
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.append(out: out.fileHandleForReading.readDataToEndOfFile())
        collected.append(err: err.fileHandleForReading.readDataToEndOfFile())
        guard process.terminationStatus == 0 else {
            let last = collected.errText.split(separator: "\n").last.map(String.init) ?? L("ffmpeg 오류 \(process.terminationStatus)", "ffmpeg error \(process.terminationStatus)")
            throw FileSkillError.exportFailed(last)
        }
        return collected.outText
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func append(out data: Data) { lock.lock(); out.append(data); lock.unlock() }
        func append(err data: Data) { lock.lock(); err.append(data); lock.unlock() }
        var outText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
        var errText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
    }
}
