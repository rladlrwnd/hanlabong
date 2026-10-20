import os

/// `log stream --predicate 'subsystem == "app.dragedit"'` 로 확인할 수 있다.
/// 사용자가 드래그한 글자 내용 자체는 절대 로그에 남기지 않는다(길이만 남김).
package let log = Logger(subsystem: "app.dragedit", category: "app")
