import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import SkillEngine

/// 사진 편집 블록(회전·반전·보정)과 영상 변환(자르기·소리 끄기·소리만·해상도)
struct PhotoEditTests {
    private let executor = FileSkillExecutor()
    private func skill(_ steps: [FileStep]) -> FileSkill {
        FileSkill(id: "t", name: "t", input: [.image, .raw], steps: [.decode] + steps + [.encode(EncodeSpec(format: .png))], output: FileOutput(suffix: "_t"))
    }
    /// 왼쪽 위만 빨간 4×2 사진
    private func marker(in dir: URL) throws -> URL {
        try Fixtures.write(Fixtures.rgb(width: 4, height: 2) { x, y in (x == 0 && y == 0) ? (255, 0, 0, 255) : (0, 0, 255, 255) },
                           to: dir.appendingPathComponent("m.png"), type: .png)
    }
    private func redCorner(_ steps: [FileStep]) throws -> (w: Int, h: Int, x: Int, y: Int) {
        let result = try executor.run(skill(steps), input: marker(in: Fixtures.makeTempDir()))
        let pixels = Fixtures.rgba(Fixtures.cgImage(of: result.data), in: Fixtures.sRGB)
        for y in 0..<result.height { for x in 0..<result.width where Fixtures.pixel(pixels, width: result.width, x: x, y: y).r > 200 { return (result.width, result.height, x, y) } }
        return (result.width, result.height, -1, -1)
    }

    @Test func rotationsMoveTheMarkerLikeAClock() throws {
        #expect(try redCorner([.rotate(degrees: 90)]) == (2, 4, 1, 0))       // 시계 90도: 왼쪽 위 → 오른쪽 위
        #expect(try redCorner([.rotate(degrees: 180)]) == (4, 2, 3, 1))
        #expect(try redCorner([.rotate(degrees: 270)]) == (2, 4, 0, 3))
        #expect(try redCorner([.rotate(degrees: -90)]) == (2, 4, 0, 3))      // 반시계 = 270
        #expect(try redCorner([.rotate(degrees: 0)]) == (4, 2, 0, 0))
    }

    @Test func flipsMirrorTheMarker() throws {
        #expect(try redCorner([.flip(horizontal: true, vertical: false)]) == (4, 2, 3, 0))
        #expect(try redCorner([.flip(horizontal: false, vertical: true)]) == (4, 2, 0, 1))
        #expect(try redCorner([.flip(horizontal: true, vertical: true)]) == (4, 2, 3, 1))
    }

    @Test func rotateThenCropUsesTheRotatedPicture() throws {
        // 회전한 그림 기준으로 오른쪽 위 1/2 영역만 잘라도 빨간 모서리가 들어 있다
        let steps: [FileStep] = [.rotate(degrees: 90), .crop(CropSpec(rect: .init(x: 0.5, y: 0, width: 0.5, height: 0.5)))]
        let result = try executor.run(skill(steps), input: marker(in: Fixtures.makeTempDir()))
        #expect(result.width == 1 && result.height == 2)
        let pixels = Fixtures.rgba(Fixtures.cgImage(of: result.data), in: Fixtures.sRGB)
        #expect(Fixtures.pixel(pixels, width: 1, x: 0, y: 0).r > 200)
    }

    @Test func adjustmentsChangeBrightnessAndSaturation() throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(Fixtures.rgb(width: 8, height: 8) { _, _ in (120, 60, 60, 255) }, to: dir.appendingPathComponent("a.png"), type: .png)
        func pixel(_ steps: [FileStep]) throws -> (r: Int, g: Int, b: Int, a: Int) {
            let r = try executor.run(skill(steps), input: url)
            return Fixtures.pixel(Fixtures.rgba(Fixtures.cgImage(of: r.data), in: Fixtures.sRGB), width: 8, x: 4, y: 4)
        }
        let base = try pixel([])
        #expect(try pixel([.adjust(brightness: 0.3, contrast: 1, saturation: 1)]).r > base.r + 30)
        let gray = try pixel([.adjust(brightness: 0, contrast: 1, saturation: 0)])
        #expect(abs(gray.r - gray.g) < 6 && abs(gray.g - gray.b) < 6)               // 채도 0 = 흑백
        #expect(try pixel([.adjust(brightness: 0, contrast: 1, saturation: 1)]) == base)   // 그대로면 값이 안 바뀐다
    }

    @Test func editBlocksRoundTripThroughJSON() throws {
        let skill = FileSkill(id: "e", name: "e", input: [.image], steps: [
            .decode, .rotate(degrees: 90), .flip(horizontal: true, vertical: false),
            .crop(CropSpec(rect: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.6))),
            .adjust(brightness: 0.1, contrast: 1.2, saturation: 0.9), .encode(EncodeSpec(format: .jpg))], output: FileOutput(suffix: "_edit"))
        #expect(try JSONDecoder().decode(FileSkill.self, from: JSONEncoder().encode(skill)) == skill)
        try skill.validate()
    }
}

@Suite(.serialized)
struct VideoTests {
    private let executor = FileSkillExecutor()

    /// 코드로 만든 영상. 영상은 AVAssetWriter로(소리 없이), 소리는 AVAudioFile로 따로 만든 다음
    /// AVMutableComposition으로 합쳐서 내보낸다(작성기에 소리를 직접 넣으면 멈추는 일이 있어서).
    private func makeVideo(at url: URL, seconds: Int = 3, width: Int = 640, height: Int = 360, withAudio: Bool = true) throws {
        let silent = withAudio ? url.deletingLastPathComponent().appendingPathComponent("silent-\(UUID().uuidString).mp4") : url
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let fps = 10
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { usleep(5_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let value = UInt8(frame * 255 / (seconds * fps))
            for i in 0..<(CVPixelBufferGetBytesPerRow(pixels) * height) { base[i] = i % 4 == 3 ? 255 : value }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        guard withAudio else { return }

        // 소리(440Hz 사인파) 파일
        let wav = url.deletingLastPathComponent().appendingPathComponent("tone-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: wav, settings: format.settings)
        let frames = AVAudioFrameCount(44100 * seconds)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        pcm.frameLength = frames
        for i in 0..<Int(frames) { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100)) * 0.3 }
        try file.write(from: pcm)

        // 합치기
        try Self.mux(video: silent, audio: wav, into: url)
        try? FileManager.default.removeItem(at: silent)
        try? FileManager.default.removeItem(at: wav)
    }

    private final class Failure: @unchecked Sendable { var error: Error? }

    private static func mux(video: URL, audio: URL, into url: URL) throws {
        let failure = Failure()
        let group = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let composition = AVMutableComposition()
                let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
                let range = CMTimeRange(start: .zero, duration: try await videoAsset.load(.duration))
                let vTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
                let aTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
                try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: vTrack, at: .zero)
                try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: aTrack, at: .zero)
                let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
                try await session.export(to: url, as: .mp4)
            } catch { failure.error = error }
            group.signal()
        }
        group.wait()
        if let error = failure.error { throw error }
    }

    private func video(_ spec: VideoSpec) -> FileSkill {
        FileSkill(id: "v", name: "v", input: [.video], steps: [.video(spec)], output: FileOutput(suffix: "_v"))
    }

    private struct Info { var seconds: Double; var size: CGSize; var hasAudio: Bool; var hasVideo: Bool }
    private func inspect(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        let size = try await videos.first?.load(.naturalSize) ?? .zero
        return Info(seconds: try await asset.load(.duration).seconds, size: size, hasAudio: !audios.isEmpty, hasVideo: !videos.isEmpty)
    }

    private func convert(_ spec: VideoSpec, source: URL) async throws -> (url: URL, info: Info) {
        let output = try FileJob.run(video(spec), input: source, executor: executor)
        return (output, try await inspect(output))
    }

    @Test func detectsVideoByContentAndHelpsTheWheel() throws {
        let dir = try Fixtures.makeTempDir()
        let url = dir.appendingPathComponent("영상.mp4")
        try makeVideo(at: url, seconds: 1)
        #expect(FileKindDetector.kind(of: url) == .video)
        let fake = dir.appendingPathComponent("가짜.mp4")
        try Data("그냥 글자".utf8).write(to: fake)
        #expect(FileKindDetector.kind(of: fake) != .video)
    }

    @Test func shrinksTo720pKeepingAspectAndSound() async throws {
        let dir = try Fixtures.makeTempDir()
        let source = dir.appendingPathComponent("원본.mp4")
        try makeVideo(at: source, width: 1920, height: 1080)
        let result = try await convert(VideoSpec(preset: .p720), source: source)
        #expect(result.url.lastPathComponent == "원본_v.mp4")
        #expect(result.info.size.width <= 1280 && result.info.size.height <= 720)
        #expect(abs(result.info.size.width / result.info.size.height - 16.0 / 9) < 0.02)
        #expect(result.info.hasAudio && abs(result.info.seconds - 3) < 0.4)
        #expect(FileManager.default.fileExists(atPath: source.path))                 // 원본은 그대로
    }

    @Test func trimsToTheChosenRange() async throws {
        let dir = try Fixtures.makeTempDir()
        let source = dir.appendingPathComponent("긴.mp4")
        try makeVideo(at: source, seconds: 4)
        let fast = try await convert(VideoSpec(preset: .passthrough, trimStart: 1, trimEnd: 3), source: source)      // 다시 인코딩 안 함
        #expect(abs(fast.info.seconds - 2) < 0.5)
        let encoded = try await convert(VideoSpec(preset: .p480, trimStart: 0.5, trimEnd: 1.5), source: source)
        #expect(abs(encoded.info.seconds - 1) < 0.4)
    }

    @Test func mutingRemovesTheSoundTrack() async throws {
        let dir = try Fixtures.makeTempDir()
        let source = dir.appendingPathComponent("소리.mp4")
        try makeVideo(at: source)
        #expect(try await inspect(source).hasAudio)
        let muted = try await convert(VideoSpec(preset: .p480, muted: true), source: source)
        #expect(muted.info.hasVideo && !muted.info.hasAudio)
    }

    @Test func extractsTheSoundAsM4A() async throws {
        let dir = try Fixtures.makeTempDir()
        let source = dir.appendingPathComponent("노래.mp4")
        try makeVideo(at: source, seconds: 2)
        let result = try await convert(VideoSpec(preset: .audioOnly), source: source)
        #expect(result.url.pathExtension == "m4a")
        #expect(result.info.hasAudio && !result.info.hasVideo && abs(result.info.seconds - 2) < 0.4)
    }

    @Test func explainsMissingSoundAndRefusesPhotos() async throws {
        let dir = try Fixtures.makeTempDir()
        let silent = dir.appendingPathComponent("무음.mp4")
        try makeVideo(at: silent, seconds: 1, withAudio: false)
        #expect(throws: FileSkillError.noAudio("무음.mp4")) { try executor.run(video(VideoSpec(preset: .audioOnly)), input: silent) }
        let photo = try Fixtures.write(Fixtures.noise(width: 10, height: 10), to: dir.appendingPathComponent("p.png"), type: .png)
        #expect(throws: FileSkillError.wrongKind(file: "p.png")) { try executor.run(video(VideoSpec(preset: .p720)), input: photo) }
    }

    @Test func cancellingStopsTheExportAndLeavesNothingBehind() throws {
        let dir = try Fixtures.makeTempDir()
        let source = dir.appendingPathComponent("취소.mp4")
        try makeVideo(at: source, seconds: 2, width: 640, height: 360)
        let flag = FileCancellation()
        flag.cancel()
        #expect(throws: CancellationError.self) { try executor.run(video(VideoSpec(preset: .p1080)), input: source, cancellation: flag) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "취소.mp4" }
        #expect(leftovers.isEmpty)
    }

    @Test func videoBlocksRoundTripThroughJSONAndRefusePhotoBlocks() throws {
        for skill in DefaultFileSkills.videoPresets + [DefaultFileSkills.videoAudio] {
            try skill.validate()
            #expect(try JSONDecoder().decode(FileSkill.self, from: JSONEncoder().encode(skill)) == skill)
        }
        let trimmed = video(VideoSpec(preset: .p720, trimStart: 1.5, trimEnd: 9, muted: true))
        #expect(try JSONDecoder().decode(FileSkill.self, from: JSONEncoder().encode(trimmed)) == trimmed)
        let mixed = FileSkill(id: "x", name: "x", input: [.video], steps: [.rotate(degrees: 90), .video(VideoSpec(preset: .p720))], output: FileOutput(suffix: ""))
        #expect(throws: FileSkillError.self) { try mixed.validate() }
    }
}

/// AVI 같은 형식은 설치된 ffmpeg로 바꾼다(ffmpeg가 없는 맥에서는 건너뛴다)
@Suite(.serialized, .enabled(if: FFmpeg.executable != nil))
struct FFmpegVideoTests {
    private let executor = FileSkillExecutor()

    private func makeAVI(_ url: URL, seconds: Int = 3, withAudio: Bool = true) throws {
        let p = Process()
        p.executableURL = FFmpeg.executable
        var args = ["-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=15:duration=\(seconds)"]
        if withAudio { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-c:a", "pcm_s16le"] }
        args += ["-c:v", "mjpeg", "-q:v", "5", url.path]
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    private func video(_ spec: VideoSpec) -> FileSkill {
        FileSkill(id: "v", name: "v", input: [.video], steps: [.video(spec)], output: FileOutput(suffix: "_v"))
    }

    @Test func aviIsDetectedAndConvertedTo480pMP4WithSound() throws {
        let dir = try Fixtures.makeTempDir()
        let source = dir.appendingPathComponent("옛날 영상.avi")
        try makeAVI(source)
        #expect(FileKindDetector.kind(of: source) == .video)
        let output = try FileJob.run(video(VideoSpec(preset: .p480)), input: source, executor: executor)
        #expect(output.lastPathComponent == "옛날 영상_v.mp4")
        let info = try FFmpeg.probe(output)
        #expect(info.hasVideo && info.hasAudio && abs(info.duration - 3) < 0.4)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func aviTrimMuteAndSoundOnly() throws {
        let dir = try Fixtures.makeTempDir()
        let source = dir.appendingPathComponent("a.avi")
        try makeAVI(source, seconds: 4)
        let trimmed = try FileJob.run(video(VideoSpec(preset: .p720, trimStart: 1, trimEnd: 3, muted: true)), input: source, executor: executor)
        let t = try FFmpeg.probe(trimmed)
        #expect(abs(t.duration - 2) < 0.4 && t.hasVideo && !t.hasAudio)
        let sound = try FileJob.run(video(VideoSpec(preset: .audioOnly)), input: source, executor: executor)
        #expect(sound.pathExtension == "m4a")
        let s = try FFmpeg.probe(sound)
        #expect(s.hasAudio && !s.hasVideo)
    }

    @Test func silentAviExplainsMissingSoundAndCancelLeavesNothing() throws {
        let dir = try Fixtures.makeTempDir()
        let source = dir.appendingPathComponent("무음.avi")
        try makeAVI(source, seconds: 1, withAudio: false)
        #expect(throws: FileSkillError.noAudio("무음.avi")) { try executor.run(video(VideoSpec(preset: .audioOnly)), input: source) }
        let flag = FileCancellation()
        flag.cancel()
        #expect(throws: CancellationError.self) { try executor.run(video(VideoSpec(preset: .p720)), input: source, cancellation: flag) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["무음.avi"])
    }
}

/// ffmpeg 입력 안전장치: 이름만 영상인 재생목록이 다른 파일·인터넷 주소를 읽게 하지 못한다
@Suite(.serialized, .enabled(if: FFmpeg.executable != nil))
struct FFmpegSafetyTests {
    @Test func playlistPretendingToBeVideoIsRejected() throws {
        let dir = try Fixtures.makeTempDir()
        let secret = dir.appendingPathComponent("secret.txt")
        try "do not read me".write(to: secret, atomically: true, encoding: .utf8)
        for ext in ["avi", "mkv", "ts"] {
            let fake = dir.appendingPathComponent("evil.\(ext)")
            try "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10.0,\nfile://\(secret.path)\n#EXTINF:10.0,\nhttp://127.0.0.1:9/x.ts\n#EXT-X-ENDLIST\n".write(to: fake, atomically: true, encoding: .utf8)
            #expect(!FFmpeg.isRealVideo(fake))
            #expect(throws: (any Error).self) { try FFmpeg.probe(fake) }
            let skill = FileSkill(id: "v", name: "v", input: [.video], steps: [.video(VideoSpec(preset: .p720))], output: FileOutput(suffix: "_v"))
            #expect(throws: (any Error).self) { try FileSkillExecutor().run(skill, input: fake) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["evil.avi", "evil.mkv", "evil.ts", "secret.txt"])
    }

    @Test func guardArgumentsComeBeforeTheInput() {
        let args = FFmpeg.arguments(VideoSpec(preset: .p720), input: URL(fileURLWithPath: "/tmp/a.avi"), output: URL(fileURLWithPath: "/tmp/b.mp4"), start: nil, end: nil)
        let input = args.firstIndex(of: "-i")!
        #expect(args.firstIndex(of: "-protocol_whitelist")! < input && args.firstIndex(of: "-format_whitelist")! < input)
        #expect(!(args[args.firstIndex(of: "-format_whitelist")! + 1]).contains("hls"))
    }
}
