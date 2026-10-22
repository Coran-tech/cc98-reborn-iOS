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
    @State private var originalFields: [String] = []
    @State private var showExit = false
    @State private var avatarStatus = ""

    private var fields: [String] { [introduction, signature, email, qq, String(gender), birthday] }
    private var changed: Bool { loaded && fields != originalFields }

    var body: some View {
        Form {
            Section("头像") {
                HStack(spacing: 14) {
                    NativeAvatar(url: auth.profile?.avatarURL ?? NativeAvatarURLs.defaultURL(gender: auth.profile?.gender), name: auth.profile?.name, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            Label(uploadingAvatar ? "上传中…" : "更换头像", systemImage: "photo")
                                .font(ShellTheme.Fonts.body)
                                .frame(minHeight: 44)
                                .foregroundStyle(ShellTheme.accent)
                        }
                        .disabled(uploadingAvatar || saving)
                        .accessibilityIdentifier("profile.avatar")
                        Text(avatarStatus.isEmpty ? "选择照片后立即上传并更换头像，返回不会撤销。" : avatarStatus)
                            .font(ShellTheme.Fonts.footnote)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("生日").font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
                    TextField("YYYY-MM-DD", text: $birthday).keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("profile.birthday")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("QQ").font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
                    TextField("QQ 号码", text: $qq).keyboardType(.numberPad)
                        .accessibilityIdentifier("profile.qq")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("邮箱").font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
                    TextField("邮箱地址", text: $email)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .accessibilityIdentifier("profile.email")
                }
            }

            Section("个人简介") {
                TextEditor(text: $introduction)
                    .font(ShellTheme.Fonts.body)
                    .accessibilityLabel("个人简介")
                    .accessibilityIdentifier("profile.introduction")
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
            }

            Section("签名档（UBB）") {
                TextEditor(text: $signature)
                    .font(ShellTheme.Fonts.body)
                    .accessibilityLabel("签名档 UBB 源码")
                    .accessibilityIdentifier("profile.signature")
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
                Text("签名档支持 UBB，会显示在帖子下方。")
                    .font(ShellTheme.Fonts.footnote)
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
        .disabled(saving)
        .navigationTitle("编辑资料")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .tabBar)
        .interactiveDismissDisabled(changed || saving || uploadingAvatar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { if changed { showExit = true } else { dismiss() } } label: {
                    Label("返回", systemImage: "chevron.left").frame(minHeight: 44)
                }.disabled(saving || uploadingAvatar)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") { Task { await save() } }
                    .frame(minHeight: 44)
                    .disabled(saving || uploadingAvatar || !loaded)
                    .accessibilityIdentifier("profile.save")
            }
        }
        .confirmationDialog("资料尚未保存", isPresented: $showExit, titleVisibility: .visible) {
            Button("保存并返回") { Task { await save() } }
            Button("丢弃未保存资料", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        } message: { Text("已更换的头像立即生效，不受此处保存或丢弃影响。") }
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
        originalFields = fields
        loaded = true
    }

    @MainActor
    private func save() async {
        guard let user = auth.profile else {
            errorMessage = "请先登录。"
            return
        }
        guard !saving, !uploadingAvatar else { return }
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
            avatarStatus = "头像已更换；下方资料仍需点击保存。"
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
        .navigationTitle("我的主题与回复")
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
    @State private var linkedTopic: NativeLinkedTopic? = nil
    @State private var linkedBoard: NativeLinkedBoard? = nil
    @State private var linkedUser: NativeLinkedUser? = nil

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
                                .font(ShellTheme.Fonts.footnote)
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
        .environment(\.openURL, OpenURLAction { url in
            if let topic = NativeLinkedTopic(url: url) {
                linkedTopic = topic
                return .handled
            }
            if let board = NativeLinkedBoard(url: url) {
                linkedBoard = board
                return .handled
            }
            if let user = NativeLinkedUser(url: url) {
                linkedUser = user
                return .handled
            }
            return .systemAction
        })
        .navigationDestination(item: $linkedTopic) { link in
            TopicDetailView(topicID: link.id, boardID: nil, initialPage: link.page, initialFloor: link.floor)
        }
        .navigationDestination(item: $linkedBoard) { link in
            BoardTopicsView(board: NativeBoard.placeholder(id: link.id))
        }
        .navigationDestination(item: $linkedUser) { link in
            UserProfileView(userID: link.userID, userName: link.userName)
        }
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
    @State private var linkedTopic: NativeLinkedTopic? = nil
    @State private var linkedBoard: NativeLinkedBoard? = nil
    @State private var linkedUser: NativeLinkedUser? = nil

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
                                initialPage: pageForFloor(item.floor),
                                initialFloor: item.floor
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
                                .font(ShellTheme.Fonts.footnote)
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
        .environment(\.openURL, OpenURLAction { url in
            if let topic = NativeLinkedTopic(url: url) {
                linkedTopic = topic
                return .handled
            }
            if let board = NativeLinkedBoard(url: url) {
                linkedBoard = board
                return .handled
            }
            if let user = NativeLinkedUser(url: url) {
                linkedUser = user
                return .handled
            }
            return .systemAction
        })
        .navigationDestination(item: $linkedTopic) { link in
            TopicDetailView(topicID: link.id, boardID: nil, initialPage: link.page, initialFloor: link.floor)
        }
        .navigationDestination(item: $linkedBoard) { link in
            BoardTopicsView(board: NativeBoard.placeholder(id: link.id))
        }
        .navigationDestination(item: $linkedUser) { link in
            UserProfileView(userID: link.userID, userName: link.userName)
        }
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
