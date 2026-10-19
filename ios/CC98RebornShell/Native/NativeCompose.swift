import SwiftUI
import PhotosUI
import UIKit

struct ComposerImageButton: View {
    @EnvironmentObject private var app: NativeAppModel
    @Binding var text: String

    @State private var item: PhotosPickerItem?
    @State private var uploading = false
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Label(uploading ? "上传中…" : "插入图片", systemImage: uploading ? "arrow.up.circle" : "photo")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.accent)
        }
        .disabled(uploading)
        .onChange(of: item) { _, newItem in
            Task { await upload(newItem) }
        }
        .alert("图片上传失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @MainActor
    private func upload(_ selection: PhotosPickerItem?) async {
        guard let selection else { return }
        uploading = true
        defer { uploading = false }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self) else {
                throw NSError(domain: "CC98Reborn", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取所选图片。"])
            }
            let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
            let url = try await app.api.uploadImage(jpeg)
            text += "\n[img]\(url)[/img]\n"
            item = nil
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

struct NewTopicComposer: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @Environment(\.dismiss) private var dismiss

    let boardID: Int
    let boardName: String
    var onCreated: () -> Void

    @State private var title = ""
    @State private var content = ""
    @State private var anonymous = false
    @State private var sending = false
    @State private var errorMessage: String? = nil
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(boardName)
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.secondaryText)

                    TextField("主题标题", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)

                    TextEditor(text: $content)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 260)
                        .padding(8)
                        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ShellTheme.separator, lineWidth: 0.5)
                        )

                    HStack {
                        ComposerImageButton(text: $content)
                        Spacer()
                        Text("\(content.count) / 8000")
                            .font(ShellTheme.Fonts.caption)
                            .foregroundStyle(content.count > 8000 ? ShellTheme.danger : ShellTheme.secondaryText)
                    }

                    Toggle("匿名发布", isOn: $anonymous)
                        .font(ShellTheme.Fonts.footnote)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.danger)
                    }
                }
                .padding(16)
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("发表主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") { Task { await submit() } }
                        .disabled(sending || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }

    @MainActor
    private func submit() async {
        guard auth.profile != nil else {
            errorMessage = "请先登录。"
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = "请输入标题。"
            return
        }
        guard !trimmedContent.isEmpty else {
            errorMessage = "请输入正文。"
            return
        }
        guard trimmedContent.count <= 8000 else {
            errorMessage = "正文不能超过 8000 个字。"
            return
        }
        guard !sending else { return }
        sending = true
        errorMessage = nil
        do {
            try await app.api.newTopic(
                boardID: boardID,
                title: trimmedTitle,
                content: content,
                isAnonymous: anonymous
            )
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        sending = false
    }
}

struct EditPostComposer: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @Environment(\.dismiss) private var dismiss

    let post: NativePost
    let topicTitle: String?
    var onSaved: () -> Void

    @State private var title: String
    @State private var content: String
    @State private var saving = false
    @State private var errorMessage: String? = nil

    init(post: NativePost, topicTitle: String?, onSaved: @escaping () -> Void) {
        self.post = post
        self.topicTitle = topicTitle
        self.onSaved = onSaved
        _title = State(initialValue: post.floor == 1 ? (topicTitle ?? "") : "")
        _content = State(initialValue: post.content ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(post.floor == 1 ? "编辑主题" : "编辑 \(post.floor ?? 0) 楼")
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.secondaryText)

                    if post.floor == 1 {
                        TextField("主题标题", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    TextEditor(text: $content)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 260)
                        .padding(8)
                        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ShellTheme.separator, lineWidth: 0.5)
                        )

                    HStack {
                        ComposerImageButton(text: $content)
                        Spacer()
                        Text("\(content.count) / 8000")
                            .font(ShellTheme.Fonts.caption)
                            .foregroundStyle(content.count > 8000 ? ShellTheme.danger : ShellTheme.secondaryText)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.danger)
                    }
                }
                .padding(16)
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @MainActor
    private func save() async {
        guard auth.profile != nil else {
            errorMessage = "请先登录。"
            return
        }
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            errorMessage = "请输入正文。"
            return
        }
        guard trimmedContent.count <= 8000 else {
            errorMessage = "正文不能超过 8000 个字。"
            return
        }
        guard !saving else { return }
        saving = true
        errorMessage = nil
        do {
            try await app.api.editPost(
                postID: post.id,
                title: post.floor == 1 ? title.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                content: content,
                contentType: post.contentType ?? 0
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }
}

struct TopicNoteView: View {
    @EnvironmentObject private var library: NativeLibrary
    @Environment(\.dismiss) private var dismiss

    let topicID: Int
    let topicTitle: String

    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(topicTitle)
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
                    .lineLimit(2)
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ShellTheme.separator, lineWidth: 0.5)
                    )
                Text("\(text.count) / 500 · 仅保存在本机")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
            .padding(16)
            .background(ShellTheme.pageBackground)
            .navigationTitle("主题备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        library.setNote(text, for: topicID)
                        dismiss()
                    }
                }
            }
            .onAppear { text = library.note(for: topicID) }
        }
    }
}
