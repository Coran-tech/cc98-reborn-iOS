import SwiftUI
import PhotosUI
import UIKit

struct ProfileSettingsView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @Environment(\.dismiss) private var dismiss

    @State private var introduction = ""
    @State private var signature = ""
    @State private var email = ""
    @State private var qq = ""
    @State private var gender = 0
    @State private var birthday = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var uploadingAvatar = false
    @State private var errorMessage: String? = nil
    @State private var avatarItem: PhotosPickerItem?

    var body: some View {
        Form {
            Section("头像") {
                HStack(spacing: 14) {
                    NativeAvatar(url: auth.profile?.avatarURL ?? NativeAvatarURLs.defaultURL(gender: auth.profile?.gender), name: auth.profile?.name, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            Label(uploadingAvatar ? "上传中…" : "更换头像", systemImage: "photo")
                                .font(ShellTheme.Fonts.footnote)
                                .foregroundStyle(ShellTheme.accent)
                        }
                        .disabled(uploadingAvatar)
                        Text("支持从相册选择，上传后立即生效。")
                            .font(ShellTheme.Fonts.caption)
                            .foregroundStyle(ShellTheme.secondaryText)
                    }
                }
            }

            Section("基本资料") {
                Picker("性别", selection: $gender) {
                    Text("保密").tag(0)
                    Text("男").tag(1)
                    Text("女").tag(2)
                }
                TextField("生日（YYYY-MM-DD）", text: $birthday)
                    .keyboardType(.numbersAndPunctuation)
                TextField("QQ", text: $qq)
                    .keyboardType(.numberPad)
                TextField("邮箱", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
            }

            Section("个人简介") {
                TextEditor(text: $introduction)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
            }

            Section("签名档（UBB）") {
                TextEditor(text: $signature)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
                Text("签名档支持 UBB，会显示在帖子下方。")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(ShellTheme.danger)
                }
            }
        }
        .navigationTitle("编辑资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(saving)
            }
        }
        .onAppear { loadFromProfile() }
        .onChange(of: avatarItem?.itemIdentifier) { _, _ in
            Task { await uploadAvatar(avatarItem) }
        }
    }

    private func loadFromProfile() {
        guard !loaded, let user = auth.profile else { return }
        introduction = user.introduction ?? ""
        signature = user.signatureCode ?? ""
        email = user.emailAddress ?? ""
        qq = user.qq ?? ""
        gender = user.gender ?? 0
        birthday = user.birthday ?? ""
        loaded = true
    }

    @MainActor
    private func save() async {
        guard let user = auth.profile else {
            errorMessage = "请先登录。"
            return
        }
        guard !saving else { return }
        saving = true
        errorMessage = nil
        do {
            try await app.api.updateProfile(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                gender: gender,
                introduction: introduction,
                qq: qq.trimmingCharacters(in: .whitespacesAndNewlines),
                signature: signature,
                birthday: birthday.trimmingCharacters(in: .whitespacesAndNewlines),
                displayTitleID: user.displayTitleId ?? 0,
                userTitleIDs: user.userTitleIds ?? []
            )
            await auth.refreshProfile()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }

    @MainActor
    private func uploadAvatar(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        uploadingAvatar = true
        errorMessage = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw NSError(domain: "CC98Reborn", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取所选图片。"])
            }
            let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
            _ = try await app.api.uploadPortrait(jpeg)
            await auth.refreshProfile()
            avatarItem = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        uploadingAvatar = false
    }
}

struct MyActivityView: View {
    private enum ActivityKind: String, CaseIterable, Identifiable {
        case topics
        case replies

        var id: String { rawValue }
        var title: String { self == .topics ? "发帖" : "回复" }
    }

    @State private var kind: ActivityKind = .topics

    var body: some View {
        VStack(spacing: 0) {
            Picker("内容类型", selection: $kind) {
                ForEach(ActivityKind.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch kind {
            case .topics:
                MyTopicsView()
            case .replies:
                MyPostsView()
            }
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle("回复 + 发帖")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MyTopicsView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth

    @State private var items: [NativeMyTopic] = []
    @State private var loading = false
    @State private var error: String? = nil
    @State private var page = 0
    @State private var hasMore = true

    private let pageSize = 10

    var body: some View {
        Group {
            if auth.profile == nil {
                LoginGateView()
            } else if items.isEmpty && loading {
                ProgressView("正在加载我的主题…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ShellTheme.pageBackground)
            } else if items.isEmpty, let error {
                NativeStateView(icon: "doc.text", title: "主题无法加载", message: error, action: {
                    Task { await load(reset: true) }
                })
            } else if items.isEmpty {
                NativeStateView(icon: "doc.text", title: "还没有发过主题", message: nil)
            } else {
                List {
                    ForEach(items) { item in
                        NavigationLink {
                            TopicDetailView(topicID: item.id, boardID: item.boardId)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                UBBContentView(source: item.title ?? "主题 #\(item.id)")
                                HStack(spacing: 8) {
                                    if let boardID = item.boardId {
                                        Text("版面 #\(boardID)")
                                    }
                                    Spacer(minLength: 0)
                                    Text(NativeFormat.date(item.time))
                                }
                                .font(ShellTheme.Fonts.caption)
                                .foregroundStyle(ShellTheme.secondaryText)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if hasMore {
                        Button {
                            Task { await load(reset: false) }
                        } label: {
                            HStack {
                                Spacer()
                                if loading { ProgressView() }
                                Text(loading ? "正在加载…" : "加载更多")
                                Spacer()
                            }
                        }
                        .disabled(loading)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(ShellTheme.pageBackground)
                .refreshable { await load(reset: true) }
            }
        }
        .background(ShellTheme.pageBackground)
        .task { await load(reset: true) }
    }

    @MainActor
    private func load(reset: Bool) async {
        guard auth.profile != nil, !loading else { return }
        loading = true
        error = nil
        if reset { page = 0; hasMore = true }
        do {
            let fetched = try await app.api.myTopics(from: page * pageSize, size: pageSize)
            if reset {
                items = fetched
            } else {
                items.append(contentsOf: fetched)
            }
            page += 1
            hasMore = fetched.count == pageSize
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct MyPostsView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth

    @State private var items: [NativeMyPost] = []
    @State private var loading = false
    @State private var error: String? = nil
    @State private var page = 0
    @State private var hasMore = true

    private let pageSize = 10

    var body: some View {
        Group {
            if auth.profile == nil {
                LoginGateView()
            } else if items.isEmpty && loading {
                ProgressView("正在加载我的回复…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ShellTheme.pageBackground)
            } else if items.isEmpty, let error {
                NativeStateView(icon: "text.bubble", title: "回复无法加载", message: error, action: {
                    Task { await load(reset: true) }
                })
            } else if items.isEmpty {
                NativeStateView(icon: "text.bubble", title: "还没有回复", message: nil)
            } else {
                List {
                    ForEach(items) { item in
                        NavigationLink {
                            TopicDetailView(
                                topicID: item.topicId ?? 0,
                                boardID: item.boardId,
                                initialPage: pageForFloor(item.floor)
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                UBBContentView(
                                    source: item.content ?? "",
                                    markdown: item.contentType == 1
                                )
                                HStack(spacing: 8) {
                                    Text(item.topicTitle ?? "主题 #\(item.topicId ?? 0)")
                                        .lineLimit(1)
                                    if let floor = item.floor, floor > 0 {
                                        Text("\(floor) 楼")
                                    }
                                    Spacer(minLength: 0)
                                    Text(NativeFormat.date(item.time))
                                }
                                .font(ShellTheme.Fonts.caption)
                                .foregroundStyle(ShellTheme.secondaryText)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if hasMore {
                        Button {
                            Task { await load(reset: false) }
                        } label: {
                            HStack {
                                Spacer()
                                if loading { ProgressView() }
                                Text(loading ? "正在加载…" : "加载更多")
                                Spacer()
                            }
                        }
                        .disabled(loading)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(ShellTheme.pageBackground)
                .refreshable { await load(reset: true) }
            }
        }
        .background(ShellTheme.pageBackground)
        .task { await load(reset: true) }
    }

    private func pageForFloor(_ floor: Int?) -> Int {
        max(1, ((max(1, floor ?? 1)) + 9) / 10)
    }

    @MainActor
    private func load(reset: Bool) async {
        guard auth.profile != nil, !loading else { return }
        loading = true
        error = nil
        if reset { page = 0; hasMore = true }
        do {
            let fetched = try await app.api.myPosts(from: page * pageSize, size: pageSize)
            if reset {
                items = fetched
            } else {
                items.append(contentsOf: fetched)
            }
            page += 1
            hasMore = fetched.count == pageSize
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct RatingComposer: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @Environment(\.dismiss) private var dismiss

    let post: NativePost

    @State private var type = 1
    @State private var reasons: [NativeJudgeReason] = []
    @State private var selectedID: Int?
    @State private var loading = false
    @State private var submitting = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("风评类型") {
                    Picker("类型", selection: $type) {
                        Text("好评").tag(1)
                        Text("差评").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section("理由") {
                    if loading {
                        ProgressView("正在加载理由…")
                    } else if reasons.isEmpty {
                        Text("暂无可选理由。")
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.secondaryText)
                    } else {
                        ForEach(reasons) { reason in
                            Button {
                                selectedID = reason.id
                            } label: {
                                HStack {
                                    Text(reason.reason ?? "理由 #\(reason.id)")
                                        .foregroundStyle(ShellTheme.primaryText)
                                    Spacer()
                                    if selectedID == reason.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(ShellTheme.accent)
                                    }
                                }
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.danger)
                    }
                }
            }
            .navigationTitle("风评")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") { Task { await submit() } }
                        .disabled(submitting || selectedID == nil || loading)
                }
            }
            .task(id: type) { await loadReasons() }
        }
    }

    @MainActor
    private func loadReasons() async {
        guard auth.profile != nil else {
            errorMessage = "请先登录。"
            return
        }
        loading = true
        errorMessage = nil
        selectedID = nil
        do {
            let list = try await app.api.ratingReasons(type: type)
            reasons = list.filter { $0.enabled != false }
            selectedID = reasons.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    @MainActor
    private func submit() async {
        guard auth.profile != nil else {
            errorMessage = "请先登录。"
            return
        }
        guard let reasonID = selectedID else {
            errorMessage = "请选择一个理由。"
            return
        }
        guard !submitting else { return }
        submitting = true
        errorMessage = nil
        do {
            try await app.api.ratePost(postID: post.id, reasonID: reasonID, type: type)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        submitting = false
    }
}
