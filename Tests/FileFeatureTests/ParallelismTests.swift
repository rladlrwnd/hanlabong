import SkillEngine
import Testing
@testable import FileFeature

/// 변환 종류와 맥 사양에 따라 동시에 돌릴 개수
struct ParallelismTests {
    let m1Max = Parallelism.Machine(performanceCores: 8, memoryGB: 64, chip: "Apple M1 Max")
    let air = Parallelism.Machine(performanceCores: 4, memoryGB: 8, chip: "Apple M2")
    let ultra = Parallelism.Machine(performanceCores: 16, memoryGB: 128, chip: "Apple M2 Ultra")

    @Test func photosUseMemoryAndCores() {
        #expect(Parallelism.limit(for: DefaultFileSkills.web, on: m1Max) == 6)
        #expect(Parallelism.limit(for: DefaultFileSkills.web, on: air) == 2)   // 8GB여도 둘은 한다
    }

    @Test func videoFollowsEncoders() {
        #expect(Parallelism.limit(for: DefaultFileSkills.video1080, on: m1Max) == 2)
        #expect(Parallelism.limit(for: DefaultFileSkills.video1080, on: ultra) == 4)
    }

    @Test func neverMoreThanFiles() {
        #expect(FileJobRunner().concurrency(for: DefaultFileSkills.web, files: 1) == 1)
        #expect(FileJobRunner(maxConcurrent: 1).concurrency(for: DefaultFileSkills.web, files: 10) == 1)
    }
}
