import AppCore
import SkillEngine
import SwiftUI

/// 내 정보: 채우기에 쓸 이름·학교·연락처 등. 이 맥에만 저장
struct ProfileEditor: View {
    @State var profile: UserProfile
    let save: (UserProfile) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("내 정보", "My info")).font(.title3.bold())
            Text(L("계약서·신청서의 빈칸을 채울 때 써요. 이 맥에만 저장돼요. 클라우드 AI를 쓰면 채울 때 이 정보가 그 AI 서비스로 가요.",
                   "Used to fill forms. Saved only on this Mac. With a cloud AI, this info is sent to that service when filling."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($profile.entries) { $entry in
                        HStack(spacing: 8) {
                            TextField(L("항목", "Item"), text: $entry.key).textFieldStyle(.roundedBorder).frame(width: 120)
                            TextField(L("값", "Value"), text: $entry.value).textFieldStyle(.roundedBorder)
                            Button { profile.entries.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 340)
            HStack {
                Button { profile.entries.append(ProfileEntry(key: "")) } label: { Label(L("항목 더하기", "Add item"), systemImage: "plus") }
                Spacer()
                Button(L("취소", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(L("저장", "Save")) {
                    profile.entries.removeAll { $0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                    save(profile); close()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
