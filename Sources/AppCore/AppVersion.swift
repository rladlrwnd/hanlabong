import Foundation
import SkillEngine

/// 버전 이름표: "1.0.0 (빌드 8)", 개발용 빌드는 뒤에 "· 개발용"
package enum AppVersion {
    package static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-" }
    package static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-" }
    package static var isDev: Bool { (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?.hasSuffix("Dev") == true }
    package static var label: String {
        L("\(short) (빌드 \(build))", "\(short) (build \(build))") + (isDev ? L(" · 개발용", " · development") : "")
    }
}
