import Testing
@testable import HanlabongWordPro

/// 요청칸의 말이 "내 정보로 빈칸 채우기"인지
@MainActor
struct FillIntentTests {
    @Test func fillRequests() {
        for text in ["빈칸 채워줘", "채워줘", "채워 줘", "내 정보로 작성해 줘", "신청서 다 채워줘", "알아서 채워", "빈칸 전부 채워 줘"] {
            #expect(DocumentSession.wantsFill(text), "\(text)")
        }
    }

    @Test func notFillRequests() {
        for text in ["주소에 서울시 써 줘", "2026 수능 1컷을 33으로", "이 문단 존댓말로 바꿔 줘", "끝에 요약 한 문단 써 줘", "학과란에 사진과 채워줘"] {
            #expect(!DocumentSession.wantsFill(text), "\(text)")
        }
    }
}
