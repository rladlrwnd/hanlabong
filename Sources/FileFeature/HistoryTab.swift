import SkillEngine
import AppCore
import AppKit
import SwiftUI

/// 설정 › 작업 기록 탭: 휠로 바꾼 파일들. Finder에서 보기, 되돌리기(결과만 휴지통으로), 기록 지우기.
struct HistoryTab: View {
    @ObservedObject var history: JobHistory
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(L("휠로 바꾼 파일 기록이에요. 결과는 원본 옆에 저장돼요. 되돌리면 그 작업이 만든 파일만 휴지통으로 가요.", "Files converted with the wheel. Results are saved next to the originals. Undo moves only the files that job made to the Trash."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("기록 지우기…", "Clear history…")) { confirmingClear = true }
                    .disabled(history.records.isEmpty)
            }

            if history.records.isEmpty {
                ContentUnavailableView(
                    L("아직 바꾼 파일이 없어요", "No converted files yet"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(L("Finder에서 파일을 끌면서 ⇧ Shift를 눌러 휠에 놓아보세요", "Drag a file in Finder, press ⇧ Shift, and drop it on the wheel"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history.records) { record in
                    HistoryRow(record: record) {
                        let existing = record.outputURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
                        if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
                    } onUndo: {
                        history.undo(record.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .confirmationDialog(L("작업 기록을 지울까?", "Clear the history?"), isPresented: $confirmingClear) {
            Button(L("기록 지우기", "Clear history"), role: .destructive) { history.clear() }
        } message: {
            Text(L("기록만 지워지고 파일은 그대로 남아요.", "Only the history is cleared; files stay."))
        }
    }
}

private struct HistoryRow: View {
    let record: JobRecord
    let onReveal: () -> Void
    let onUndo: () -> Void

    private var detail: String {
        var parts = [record.date.formatted(date: .abbreviated, time: .shortened)]
        parts.append(record.duration < 1 ? L("1초 미만", "under 1 s") : L("\(Int(record.duration.rounded()))초", "\(Int(record.duration.rounded())) s"))
        parts.append(L("\(record.outputs.count)개 저장", "\(record.outputs.count) saved"))
        if !record.failures.isEmpty { parts.append(L("실패 \(record.failures.count)개", "\(record.failures.count) failed")) }
        if record.wasCanceled { parts.append(L("취소 \(record.canceledCount)개", "\(record.canceledCount) canceled")) }
        if record.undone { parts.append(L("되돌림", "Undone")) }
        return parts.joined(separator: " · ")
    }

    private var statusSymbol: (name: String, color: Color) {
        if record.undone { return ("arrow.uturn.backward.circle", .secondary) }
        if !record.failures.isEmpty { return ("exclamationmark.triangle.fill", .orange) }
        if record.wasCanceled { return ("xmark.circle", .secondary) }
        return ("checkmark.circle.fill", .green)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.symbol ?? "photo")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("\(record.skillName) · \(record.inputCount)개", "\(record.skillName) · \(record.inputCount) file(s)"))
                    .font(.system(size: 13.5, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: statusSymbol.name)
                .foregroundStyle(statusSymbol.color)
                .help(record.failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n"))
            Button(action: onReveal) { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help(L("결과 파일을 Finder에서 보기", "Show results in Finder"))
                .disabled(record.outputs.isEmpty || record.undone)
            Button(L("되돌리기", "Undo"), action: onUndo)
                .controlSize(.small)
                .help(L("이 작업이 만든 파일을 휴지통으로 옮겨요", "Moves the files this job made to the Trash"))
                .disabled(!record.canUndo)
        }
        .padding(.vertical, 4)
        .opacity(record.undone ? 0.6 : 1)
    }
}
