import SwiftUI

struct EmoticonCategory: Identifiable {
    let id: String
    let title: String
    let folder: String
    let filePrefix: String
    let tagPrefix: String
    let fileExtension: String?
    let ids: [String]
}

enum EmoticonCatalog {
    static let categories: [EmoticonCategory] = [
        make(id: "ac", title: "AC", folder: "ac", filePrefix: "", tagPrefix: "ac", fileExtension: "png"),
        make(id: "cc98", title: "CC98", folder: "CC98", filePrefix: "CC98", tagPrefix: "cc98", fileExtension: nil),
        make(id: "em", title: "EM", folder: "em", filePrefix: "em", tagPrefix: "em", fileExtension: "gif"),
        make(id: "ms", title: "MS", folder: "ms", filePrefix: "ms", tagPrefix: "ms", fileExtension: "png"),
        make(id: "tb", title: "TB", folder: "tb", filePrefix: "tb", tagPrefix: "tb", fileExtension: "png")
    ]

    private static func make(
        id: String,
        title: String,
        folder: String,
        filePrefix: String,
        tagPrefix: String,
        fileExtension: String?
    ) -> EmoticonCategory {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("Reborn/images/\(folder)") else {
            return EmoticonCategory(id: id, title: title, folder: folder, filePrefix: filePrefix, tagPrefix: tagPrefix, fileExtension: fileExtension, ids: [])
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        let ids = files.compactMap { url -> String? in
            if let fileExtension, url.pathExtension.lowercased() != fileExtension { return nil }
            var name = url.deletingPathExtension().lastPathComponent
            if !filePrefix.isEmpty {
                guard name.lowercased().hasPrefix(filePrefix.lowercased()) else { return nil }
                name = String(name.dropFirst(filePrefix.count))
            }
            guard !name.isEmpty else { return nil }
            return name
        }
        .sorted()
        return EmoticonCategory(
            id: id,
            title: title,
            folder: folder,
            filePrefix: filePrefix,
            tagPrefix: tagPrefix,
            fileExtension: fileExtension,
            ids: ids
        )
    }
}

struct EmoticonPicker: View {
    @Binding var text: String
    @Binding var selection: NSRange
    let editor: UBBEditorController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var categoryID = EmoticonCatalog.categories.first?.id ?? "ac"
    @AppStorage("native.recentEmoticons") private var recentRaw = ""

    private var recentTags: [String] {
        recentRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    private var category: EmoticonCategory {
        EmoticonCatalog.categories.first { $0.id == categoryID } ?? EmoticonCatalog.categories[0]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !recentTags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("最近使用")
                            .font(ShellTheme.Fonts.caption)
                            .foregroundStyle(ShellTheme.secondaryText)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recentTags, id: \.self) { tag in
                                    Button {
                                        insert(tag)
                                    } label: {
                                        if let image = UBBEmotion.image(tag, light: colorScheme == .dark, maxSide: 36) {
                                            Image(uiImage: image)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 30, height: 30)
                                                .frame(width: 44, height: 44)
                                                .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("最近表情 \(tag)")
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 8)
                }

                Picker("表情分类", selection: $categoryID) {
                    ForEach(EmoticonCatalog.categories) { item in
                        Text(item.title).tag(item.id)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                        ForEach(category.ids, id: \.self) { id in
                            Button {
                                insert(category.tagPrefix + id)
                            } label: {
                                Group {
                                    if let image = UBBEmotion.image(category.tagPrefix + id, light: colorScheme == .dark, maxSide: 36) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 30, height: 30)
                                    } else {
                                        Text(id)
                                            .font(.caption2)
                                            .foregroundStyle(ShellTheme.secondaryText)
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("表情 \(category.tagPrefix)\(id)")
                        }
                    }
                    .padding(16)
                }
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("插入表情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func insert(_ tag: String) {
        if !editor.insert("[\(tag)]") {
            UBBEditorInsertion.insert("[\(tag)]", text: &text, selection: &selection)
        }
        var tags = recentTags.filter { $0 != tag }
        tags.insert(tag, at: 0)
        recentRaw = tags.prefix(24).joined(separator: ",")
        dismiss()
    }
}

struct ComposerEmoticonButton: View {
    @Binding var text: String
    @Binding var selection: NSRange
    let editor: UBBEditorController
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Label("表情", systemImage: "face.smiling")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.accent)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("compose.emoticon")
        .sheet(isPresented: $showPicker) {
            EmoticonPicker(text: $text, selection: $selection, editor: editor)
        }
    }
}
