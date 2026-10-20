import AppCore
import SkillEngine
import SwiftUI

// MARK: - 파일 휠 편집

/// 설정 › 파일 휠: 사진·PDF 휠의 칸을 추가·삭제·순서 바꾸기. 오른쪽에 실제 휠 미리보기.
struct WheelEditorTab: View {
    @ObservedObject var store: WheelConfigStore
    let ai: () -> AIDestination?
    @State private var kind: WheelKind = .image
    @State private var focusedSlot: UUID?

    private var slots: [WheelSlotConfig] { store.config.slots(for: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $kind) {
                    ForEach(WheelKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                Text(L("\(slots.count)/\(WheelConfig.maxSlots)칸", "\(slots.count)/\(WheelConfig.maxSlots) slots")).foregroundStyle(.secondary).monospacedDigit()
                addMenu
                Button(L("기본으로", "Reset")) { store.resetWheel(kind) }
            }
            Text(L("끌어서 순서를 바꿔. 첫 칸이 12시이고 시계 방향으로 놓여. 묶음 칸은 커서를 올리면 바깥쪽에 2단계(최대 \(WheelConfig.maxChildren)칸)가 펼쳐져.", "Drag to reorder. The first slot sits at 12 o'clock, then clockwise. Hovering a group opens an outer ring (up to \(WheelConfig.maxChildren) slots)."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }

            HStack(alignment: .top, spacing: 16) {
                List {
                    ForEach(slots) { slot in
                        SlotRow(store: store, kind: kind, slot: slot, isFocused: focusedSlot == slot.id) {
                            focusedSlot = focusedSlot == slot.id ? nil : slot.id
                        }
                    }
                    .onMove { from, to in
                        store.update { config in
                            var list = config.slots(for: kind)
                            list.move(fromOffsets: from, toOffset: to)
                            config.setSlots(list, for: kind)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                WheelPreview(layout: WheelLayout.build(kind, config: store.config, ai: ai()),
                             expandSlot: slots.firstIndex { $0.id == focusedSlot && $0.isGroup })
                    .frame(width: 250, height: 250)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Section(L("놓으면 바로 실행", "Runs on drop")) {
                ForEach(store.config.availableActions(for: kind), id: \.id) { action in
                    Button { add(.action(action.id)) } label: { Label(action.title, systemImage: action.symbol) }
                }
            }
            Section {
                Button { add(.group(L("새 묶음", "New group"), symbol: "square.grid.2x2", [])) } label: {
                    Label(L("묶음(2단계) 만들기", "New group (outer ring)"), systemImage: "circle.grid.cross")
                }
            }
        } label: {
            Label(L("칸 추가", "Add slot"), systemImage: "plus")
        }
        .fixedSize()
        .disabled(slots.count >= WheelConfig.maxSlots)
    }

    private func add(_ slot: WheelSlotConfig) {
        store.update { config in config.setSlots(config.slots(for: kind) + [slot], for: kind) }
        if slot.isGroup { focusedSlot = slot.id }
    }
}

/// 칸 한 줄. 묶음이면 이름·아이콘을 바꾸고 안의 칸을 넣고 빼고 순서를 바꿀 수 있다.
private struct SlotRow: View {
    @ObservedObject var store: WheelConfigStore
    let kind: WheelKind
    let slot: WheelSlotConfig
    let isFocused: Bool
    let toggleFocus: () -> Void

    private static let symbols = ["photo", "doc.richtext", "text.alignleft", "square.grid.2x2", "star", "folder",
                                  "wand.and.stars", "sparkles", "crop", "globe", "camera", "paintpalette"]

    private func edit(_ change: (inout WheelSlotConfig) -> Void) {
        store.update { config in
            var list = config.slots(for: kind)
            guard let index = list.firstIndex(where: { $0.id == slot.id }) else { return }
            change(&list[index])
            config.setSlots(list, for: kind)
        }
    }

    var body: some View {
        if let action = slot.action {
            HStack(spacing: 10) {
                Image(systemName: store.config.symbol(of: action)).frame(width: 22)
                Text(store.config.title(of: action))
                Spacer()
                removeButton
            }
            .padding(.vertical, 3)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button { edit { $0.symbol = symbol } } label: { Label(symbol, systemImage: symbol) }
                        }
                    } label: {
                        Image(systemName: slot.symbol ?? "square.grid.2x2")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    TextField(L("묶음 이름", "Group name"), text: Binding(get: { slot.group ?? "" }, set: { name in edit { $0.group = name } }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(L("\(slot.children?.count ?? 0)칸", "\(slot.children?.count ?? 0) slots")).foregroundStyle(.secondary).font(.caption)
                    Button { toggleFocus() } label: { Image(systemName: isFocused ? "chevron.up" : "chevron.down") }
                        .buttonStyle(.borderless)
                        .help(L("안의 칸 보기", "Show slots inside"))
                    removeButton
                }
                if isFocused {
                    ForEach(Array((slot.children ?? []).enumerated()), id: \.offset) { index, child in
                        HStack(spacing: 8) {
                            Image(systemName: store.config.symbol(of: child)).frame(width: 18)
                            Text(store.config.title(of: child)).font(.system(size: 12))
                            Spacer()
                            Button { edit { $0.children?.swapAt(index, index - 1) } } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.borderless).disabled(index == 0)
                            Button { edit { $0.children?.swapAt(index, index + 1) } } label: { Image(systemName: "arrow.down") }
                                .buttonStyle(.borderless).disabled(index == (slot.children?.count ?? 0) - 1)
                            Button { edit { $0.children?.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.leading, 30)
                    }
                    Menu {
                        ForEach(store.config.availableActions(for: kind), id: \.id) { action in
                            Button { edit { $0.children = ($0.children ?? []) + [action.id] } } label: {
                                Label(action.title, systemImage: action.symbol)
                            }
                        }
                    } label: {
                        Label(L("안에 칸 추가", "Add slot inside"), systemImage: "plus")
                    }
                    .fixedSize()
                    .padding(.leading, 30)
                    .disabled((slot.children?.count ?? 0) >= WheelConfig.maxChildren)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            store.update { config in config.setSlots(config.slots(for: kind).filter { $0.id != slot.id }, for: kind) }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help(L("이 칸 빼기", "Remove this slot"))
    }
}

/// 설정 창 안의 진짜 휠(유리 그대로, 마우스로는 못 건드리는 미리보기)
private struct WheelPreview: View {
    let layout: WheelLayout
    let expandSlot: Int?
    @StateObject private var model = WheelModel(layout: .image())

    var body: some View {
        let geometry = WheelGeometry()
        WheelView(model: model)
            .frame(width: geometry.side, height: geometry.side)
            .scaleEffect(250 / geometry.side)
            .frame(width: 250, height: 250)
            .allowsHitTesting(false)
            .onAppear(perform: refresh)
            .onChange(of: layout) { _, _ in refresh() }
            .onChange(of: expandSlot) { _, _ in refresh() }
    }

    private func refresh() {
        model.setLayout(layout)
        model.isShown = true
        if let slot = expandSlot {
            let radians = Double(slot) * WheelGeometry().slotWidthDegrees * .pi / 180
            model.pointerMoved(to: CGPoint(x: 100 * sin(radians), y: 100 * cos(radians)))
        }
    }
}

// MARK: - 사진 프리셋 편집

/// 설정 › 사진 프리셋: 크기·색·메타데이터·워터마크·저장 형식. 바꾸는 즉시 저장된다.
struct PresetEditorTab: View {
    @ObservedObject var store: WheelConfigStore
    @State private var selectedID: String?
    @State private var draft: PhotoPresetDraft?

    private var isBuiltIn: Bool { DefaultFileSkills.photoPresets.contains { $0.id == selectedID } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: $selectedID) {
                    ForEach(store.config.presets) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(preset.name, systemImage: preset.symbol ?? "photo").font(.system(size: 13, weight: .medium))
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 2)
                        .tag(preset.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Button { if let id = selectedID, let new = store.duplicatePreset(id) { selectedID = new } } label: {
                        Label(L("복제", "Duplicate"), systemImage: "plus.square.on.square")
                    }
                    .disabled(selectedID == nil)
                    Button(role: .destructive) {
                        if let id = selectedID { store.deletePreset(id); selectedID = store.config.presets.first?.id }
                    } label: { Image(systemName: "trash") }
                    .disabled(selectedID == nil || isBuiltIn)
                    .help(isBuiltIn ? L("기본 프리셋은 지울 수 없어요(휠에서 빼거나 고칠 수는 있어요)", "Built-in presets can't be deleted (you can edit them or remove them from the wheel)") : L("프리셋 지우기", "Delete preset"))
                    Spacer()
                    Button(L("기본값으로", "Reset to default")) { store.resetDefaultPresets() }
                        .help(L("웹용·클라이언트 샘플·미리보기를 처음 값으로. 내가 만든 프리셋은 그대로예요", "Restores Web, Client sample and Preview. Your own presets stay"))
                }
            }
            .frame(width: 230)

            if let binding = Binding($draft) {
                PresetForm(draft: binding)
            } else {
                Text(L("왼쪽에서 프리셋을 골라줘", "Pick a preset on the left")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selectedID == nil { selectedID = store.config.presets.first?.id }; loadDraft() }
        .onChange(of: selectedID) { _, _ in loadDraft() }
        .onChange(of: store.config.presets) { _, _ in
            // 기본값으로 되돌린 경우 등: 고르고 있던 프리셋을 다시 읽는다(직접 고친 것과 같으면 그대로)
            if let preset = store.config.presets.first(where: { $0.id == selectedID }), draft?.skill != preset {
                draft = PhotoPresetDraft(preset)
            }
        }
        .onChange(of: draft) { _, new in
            guard let new, store.config.presets.first(where: { $0.id == new.id }) != new.skill else { return }
            store.savePreset(new.skill)
        }
    }

    private func loadDraft() {
        draft = store.config.presets.first { $0.id == selectedID }.map(PhotoPresetDraft.init)
    }
}

private struct PresetForm: View {
    @Binding var draft: PhotoPresetDraft

    private static let positions: [(WatermarkPosition, String)] = [
        (.topLeft, L("왼쪽 위", "Top left")), (.top, L("위", "Top")), (.topRight, L("오른쪽 위", "Top right")), (.left, L("왼쪽", "Left")), (.center, L("가운데", "Center")),
        (.right, L("오른쪽", "Right")), (.bottomLeft, L("왼쪽 아래", "Bottom left")), (.bottom, L("아래", "Bottom")), (.bottomRight, L("오른쪽 아래", "Bottom right")),
    ]

    var body: some View {
        Form {
            Section(L("이름", "Name")) {
                TextField(L("프리셋 이름", "Preset name"), text: $draft.name)
                TextField(L("파일 이름 뒤에 붙일 말", "Suffix added to the file name"), text: $draft.suffix)
                Text(L("예: DSCF0001\(draft.suffix).\(draft.format.fileExtension) — 원본 옆에 저장돼요", "e.g. DSCF0001\(draft.suffix).\(draft.format.fileExtension) — saved next to the original"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("색", "Color")) {
                Picker(L("색 공간", "Color space"), selection: $draft.colorspace) {
                    Text(L("원본 유지", "Keep original")).tag(ColorSpaceTarget.keep)
                    Text(L("sRGB (웹·SNS)", "sRGB (web · social)")).tag(ColorSpaceTarget.sRGB)
                    Text("Display P3").tag(ColorSpaceTarget.displayP3)
                }
            }
            Section(L("크기", "Size")) {
                Picker(L("줄이기", "Shrink"), selection: $draft.resizeMode) {
                    ForEach(PhotoPresetDraft.ResizeMode.allCases) { Text($0.title).tag($0) }
                }
                if draft.resizeMode != .none {
                    HStack {
                        TextField(draft.resizeMode == .percent ? L("비율", "Percent") : L("픽셀", "Pixels"), value: $draft.resizeValue, format: .number)
                        Text(draft.resizeMode == .percent ? "%" : "px").foregroundStyle(.secondary)
                    }
                    Text(L("작은 사진은 키우지 않아요", "Small photos are never enlarged")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("메타데이터", "Metadata")) {
                Picker(L("남길 정보", "Keep"), selection: $draft.metadataMode) {
                    Text(L("전부 유지", "Everything")).tag(MetadataMode.keepAll)
                    Text(L("위치(GPS)만 삭제", "Remove location (GPS) only")).tag(MetadataMode.removeGPS)
                    Text(L("카메라·촬영 정보만", "Camera & shooting info only")).tag(MetadataMode.keepCameraOnly)
                    Text(L("전부 삭제", "Remove everything")).tag(MetadataMode.removeAll)
                }
                TextField(L("작가", "Artist"), text: $draft.artist)
                TextField(L("저작권", "Copyright"), text: $draft.copyright)
            }
            Section(L("워터마크", "Watermark")) {
                Toggle(L("워터마크 넣기", "Add watermark"), isOn: $draft.watermarkOn)
                if draft.watermarkOn {
                    TextField(L("글자", "Text"), text: $draft.watermarkText)
                    Picker(L("위치", "Position"), selection: $draft.watermarkPosition) {
                        ForEach(Self.positions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    LabeledContent(L("투명도", "Opacity")) { Slider(value: $draft.watermarkOpacity, in: 0.1...1) ; Text("\(Int(draft.watermarkOpacity * 100))%").monospacedDigit().frame(width: 40) }
                    LabeledContent(L("크기", "Size")) { Slider(value: $draft.watermarkSize, in: 5...60) ; Text("\(Int(draft.watermarkSize))%").monospacedDigit().frame(width: 40) }
                    LabeledContent(L("여백", "Margin")) { Slider(value: $draft.watermarkMargin, in: 0...10) ; Text("\(Int(draft.watermarkMargin))%").monospacedDigit().frame(width: 40) }
                }
            }
            Section(L("저장 형식", "Output format")) {
                Picker(L("형식", "Format"), selection: $draft.format) {
                    Text("JPG").tag(OutputFormat.jpg)
                    Text("HEIC").tag(OutputFormat.heic)
                    Text("PNG").tag(OutputFormat.png)
                    Text("TIFF").tag(OutputFormat.tiff)
                }
                if draft.format.isLossy {
                    LabeledContent(L("품질", "Quality")) { Slider(value: $draft.quality, in: 0.4...1) ; Text("\(Int(draft.quality * 100))%").monospacedDigit().frame(width: 40) }
                }
                Toggle(L("파일 크기 제한", "File size limit"), isOn: $draft.limitSize)
                if draft.limitSize {
                    HStack {
                        TextField(L("최대 크기", "Max size"), value: $draft.maxMegabytes, format: .number)
                        Text(L("MB 이하", "MB or less")).foregroundStyle(.secondary)
                    }
                    Text(L("품질을 낮추고, 그래도 크면 크기를 줄여서 맞춰요", "Lowers quality first, then shrinks the image if still too big")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension FileFeatureController {
    /// 설정 창에 끼워 넣는 "파일 휠"·"사진 프리셋" 탭
    package func settingsTabs() -> [SettingsTab] {
        [
            SettingsTab(id: "file-wheels", title: L("파일 휠", "File wheels"), systemImage: "circle.grid.cross") { [wheelConfig, agents] in
                AnyView(WheelEditorTab(store: wheelConfig, ai: {
                    agents.agent(for: .ocrTypoFix).map { AIDestination(name: $0.name, isCloud: !$0.isLocal) }
                }))
            },
            SettingsTab(id: "photo-presets", title: L("사진 프리셋", "Photo presets"), systemImage: "camera.filters") { [wheelConfig] in
                AnyView(PresetEditorTab(store: wheelConfig))
            },
        ]
    }
}
