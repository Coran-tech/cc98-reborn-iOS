import SwiftUI
import UniformTypeIdentifiers

struct SoundBoardView: View {
    @EnvironmentObject private var store: SoundBoardStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var activeSheet: ActiveSheet?
    @State private var showingFileImporter = false
    @State private var deleteTarget: SoundItem?
    @State private var importError: String?

    private let defaultColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 14)]
        }
        return defaultColumns
    }

    var body: some View {
        ZStack {
            SoundBoardBackground()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if store.sounds.isEmpty {
                        emptyState
                    } else {
                        soundGrid
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let activeSound = store.activeSound {
                playbackBar(for: activeSound)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if store.isImporting {
                importingOverlay
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: store.activeSoundID)
        .animation(.snappy, value: store.isImporting)
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true,
            onCompletion: handleFileSelection
        )
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addLink:
                AddSoundLinkView()
                    .environmentObject(store)
            case .rename(let sound):
                RenameSoundView(sound: sound) { newTitle in
                    store.rename(sound, to: newTitle)
                }
            }
        }
        .confirmationDialog(
            deleteTarget.map { "删除「\($0.title)」？" } ?? "删除音效",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { isPresented in
                    if !isPresented {
                        deleteTarget = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let sound = deleteTarget {
                    store.delete(sound)
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) {
                deleteTarget = nil
            }
        }
        .alert(
            "导入失败",
            isPresented: Binding(
                get: { importError != nil },
                set: { isPresented in
                    if !isPresented {
                        importError = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {
                importError = nil
            }
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                store.stopAll()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("响一下")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .tracking(-1.2)
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Menu {
                importButtons
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background {
                        Circle().fill(.white.opacity(0.07))
                    }
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
            }
            .accessibilityLabel("添加音效")

            Button {
                store.toggleMute()
            } label: {
                Image(systemName: store.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(store.isMuted ? Color(hex: 0xFCA5A5) : .white)
                    .frame(width: 48, height: 48)
                    .background {
                        Circle().fill(.white.opacity(0.07))
                    }
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isMuted ? "打开声音" : "静音")
            .animation(.snappy(duration: 0.25), value: store.isMuted)
        }
    }

    @ViewBuilder
    private var importButtons: some View {
        Button {
            showingFileImporter = true
        } label: {
            Label("从文件", systemImage: "folder")
        }

        Button {
            activeSheet = .addLink
        } label: {
            Label("从链接", systemImage: "link")
        }
    }

    // MARK: - Content

    private var emptyState: some View {
        Menu {
            importButtons
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))

                Text("添加音效")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.62))
            .frame(maxWidth: .infinity, minHeight: 210)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        .white.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 7])
                    )
            }
        }
        .accessibilityLabel("添加音效")
    }

    private var soundGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(store.sounds) { sound in
                SoundCardView(
                    sound: sound,
                    isActive: store.activeSoundID == sound.id,
                    isMuted: store.isMuted,
                    onPlay: { store.play(sound) },
                    onRename: { activeSheet = .rename(sound) },
                    onDelete: { deleteTarget = sound }
                )
            }
        }
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .padding(24)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
        }
    }

    // MARK: - Playback

    private func playbackBar(for sound: SoundItem) -> some View {
        HStack(spacing: 12) {
            EqualizerBars(color: sound.accentColor)
                .frame(width: 26, height: 18)

            Text(sound.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                store.stopAll()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止播放")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.30), radius: 18, x: 0, y: 10)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
    }

    // MARK: - File import

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task { @MainActor in
                if let message = await store.importFiles(urls) {
                    importError = message
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

// MARK: - Sheets

private enum ActiveSheet: Identifiable {
    case addLink
    case rename(SoundItem)

    var id: String {
        switch self {
        case .addLink:
            return "addLink"
        case .rename(let sound):
            return "rename-\(sound.id.uuidString)"
        }
    }
}

private struct RenameSoundView: View {
    let sound: SoundItem
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @FocusState private var isFocused: Bool

    init(sound: SoundItem, onSave: @escaping (String) -> Void) {
        self.sound = sound
        self.onSave = onSave
        _title = State(initialValue: sound.title)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("名称", text: $title)
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.07))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color(hex: 0x0B0D18).ignoresSafeArea())
            .navigationTitle("重命名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(trimmedTitle.isEmpty)
                }
            }
        }
        .presentationDetents([.height(190)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear {
            isFocused = true
        }
    }

    private func save() {
        guard !trimmedTitle.isEmpty else { return }
        onSave(trimmedTitle)
        dismiss()
    }
}

// MARK: - Equalizer

private struct EqualizerBars: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: index == 1 ? 14 : 8)
                }
            }
            .frame(width: 28, height: 18)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                let time = context.date.timeIntervalSinceReferenceDate

                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        let wave = abs(sin(time * 9 + Double(index) * 1.2))
                        let barHeight = 5 + 13 * CGFloat(wave)
                        Capsule()
                            .fill(color)
                            .frame(width: 3, height: barHeight)
                    }
                }
                .frame(width: 28, height: 18)
            }
        }
    }
}

// MARK: - Background

private struct SoundBoardBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(hex: 0x080A12),
                Color(hex: 0x0D1022),
                Color(hex: 0x160A28)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay {
            GeometryReader { proxy in
                ZStack {
                    Circle()
                        .fill(Color(hex: 0x7C3AED).opacity(0.32))
                        .frame(width: proxy.size.width * 0.95, height: proxy.size.width * 0.95)
                        .blur(radius: 90)
                        .position(x: proxy.size.width * 0.10, y: proxy.size.height * 0.06)

                    Circle()
                        .fill(Color(hex: 0x0EA5E9).opacity(0.15))
                        .frame(width: proxy.size.width * 0.85, height: proxy.size.width * 0.85)
                        .blur(radius: 110)
                        .position(x: proxy.size.width * 0.94, y: proxy.size.height * 0.52)

                    Circle()
                        .fill(Color(hex: 0xEC4899).opacity(0.10))
                        .frame(width: proxy.size.width * 0.8, height: proxy.size.width * 0.8)
                        .blur(radius: 100)
                        .position(x: proxy.size.width * 0.22, y: proxy.size.height * 0.94)
                }
            }
        }
        .ignoresSafeArea()
    }
}

#Preview("Sound Board") {
    SoundBoardView()
        .environmentObject(SoundBoardStore())
}
