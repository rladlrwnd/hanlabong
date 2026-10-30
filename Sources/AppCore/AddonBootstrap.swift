import Foundation
import SkillEngine

/// 애드온 앱(Hanlabong Developing·PDF)이 켜질 때: 언어·강조색을 한라봉 본체 설정에서 가져온다.
/// 애드온은 식별자가 달라서 설정 저장소가 따로라, 본체에서 바꾼 값을 여기서 읽어 맞춘다.
package enum AddonBootstrap {
    package static let mainAppDomain = "app.dragedit.DragEdit"

    package static func syncFromMainApp() {
        guard let main = UserDefaults(suiteName: mainAppDomain) else { return }
        let local = UserDefaults.standard
        for key in [AppLanguage.defaultsKey, AppAccent.key] {
            if let value = main.object(forKey: key) { local.set(value, forKey: key) } else { local.removeObject(forKey: key) }
        }
    }
}
