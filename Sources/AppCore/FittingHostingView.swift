import AppKit
import SwiftUI

/// SwiftUI 내용물 크기가 바뀔 때마다 알려주는 호스팅 뷰.
/// SwiftUI는 화면 내용을 "다음 순간"에 다시 그리기 때문에, 내용을 바꾼 직후 크기를 재면
/// 이전 내용의 크기가 나온다(그래서 팝업이 작게 열려 목록이 잘렸다). 실제로 다시 그려진 뒤
/// 이 신호를 받아 창 크기를 맞춘다.
package final class FittingHostingView<Content: View>: NSHostingView<Content> {
    package var onIntrinsicSizeInvalidated: (() -> Void)?

    package required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    package override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
    }
}
