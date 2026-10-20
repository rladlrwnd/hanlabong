import Foundation

/// 앱 언어(한국어·영어). 설정 › 일반 › 언어에서 고르고, 앱을 다시 켜면 바뀐다.
/// 문자열 파일 대신 코드 안에 두 언어를 나란히 적는다(`L("한국어", "English")`) — 빠뜨린 번역이 컴파일할 때 바로 보인다.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, korean = "ko", english = "en"

    public static let defaultsKey = "appLanguage"

    /// 설정에서 고른 값
    public static var choice: AppLanguage {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 이번 실행에서 쓰는 언어(켤 때 한 번 정한다)
    public static let isKorean: Bool = {
        switch choice {
        case .korean: return true
        case .english: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        }
    }()

    public var title: String {
        switch self {
        case .system: return L("시스템 설정 따르기", "Match system")
        case .korean: return "한국어"
        case .english: return "English"
        }
    }
}

/// 지금 언어에 맞는 쪽을 고른다
@inline(__always)
public func L(_ korean: String, _ english: String) -> String {
    AppLanguage.isKorean ? korean : english
}
