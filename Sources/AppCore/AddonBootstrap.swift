import Foundation
import SkillEngine

/// 애드온 앱(Hanlabong Developing·PDF)이 켜질 때: 언어·강조색을 한라봉 본체 설정에서 가져온다.
/// 애드온은 식별자가 달라서 설정 저장소가 따로라, 본체에서 바꾼 값을 여기서 읽어 맞춘다.
package enum AddonBootstrap {
    package static let mainAppDomain = "app.dragedit.DragEdit"

    /// AI 설정(고른 에이전트·클라우드 켜짐·기능별 에이전트·클라우드 모델). API 키는 키체인이라 따로 안 옮겨도 된다
    static var aiKeys: [String] { ["selectedAgentID", "cloudAIEnabled", "featureAgentIDs", AIClient.keepAliveDefaultsKey] + AgentProvider.cloud.map { "cloudModel.\($0.rawValue)" } }

    /// 켤 때: 언어·강조색 + AI 설정
    package static func syncFromMainApp() { copy([AppLanguage.defaultsKey, AppAccent.key] + aiKeys) }

    /// AI에 부탁하기 바로 전에: 애드온이 켜져 있는 사이에 본체에서 로컬/클라우드를 바꿨을 수 있어서 매번 다시 읽는다
    package static func syncAISettings() { copy(aiKeys) }

    private static func copy(_ keys: [String]) {
        guard let main = UserDefaults(suiteName: mainAppDomain) else { return }
        let local = UserDefaults.standard
        for key in keys {
            if let value = main.object(forKey: key) { local.set(value, forKey: key) } else { local.removeObject(forKey: key) }
        }
    }
}
