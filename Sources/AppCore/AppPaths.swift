import Foundation

/// 앱 데이터 폴더: ~/Library/Application Support/DragEdit
package enum AppPaths {
    package static let supportFolder = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DragEdit", isDirectory: true)
}
