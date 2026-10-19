import SwiftUI
import UIKit
import Foundation
import ImageIO

// Block-level UBB renderer for native topic posts. It handles the tags that
// appear in real CC98 content: inline emphasis/color/links, quotes, code,
// images, emotions, lists, tables, alignment and media placeholders.
enum UBBAlignment {
    case leading, center, trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

enum UBBInline {
    case text(AttributedString)
    case emotion(String)
}

indirect enum UBBBlock {
    case text([UBBInline], UBBAlignment)
    case heading(String, Int)
    case image(URL?, String?, Bool)
    case quote([UBBBlock])
    case code(String)
    case divider
    case list([String])
    case table([[String]])
    case media(String, URL?)
}

extension UBBBlock {
    var images: [URL] {
        switch self {
        case let .image(url, _, _):
            return url.map { [$0] } ?? []
        case let .quote(blocks):
            return blocks.flatMap(\.images)
        default:
            return []
        }
    }
}

private struct UBBGalleryKey: EnvironmentKey {
    static let defaultValue: [URL] = []
}

extension EnvironmentValues {
    var ubbGallery: [URL] {
        get { self[UBBGalleryKey.self] }
        set { self[UBBGalleryKey.self] = newValue }
    }
}

struct UBBContentView: View {
    let source: String
    var markdown: Bool = false

    private var blocks: [UBBBlock] {
        UBBBlockParser.parse(source, markdown: markdown)
    }

    var body: some View {
        UBBBlocksView(blocks: blocks)
            .environment(\.ubbGallery, blocks.flatMap(\.images))
    }
}

struct UBBBlocksView: View {
    let blocks: [UBBBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                UBBBlockView(block: blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UBBBlockView: View {
    let block: UBBBlock

    @ViewBuilder
    var body: some View {
        switch block {
        case let .text(inlines, alignment):
            UBBInlineText(inlines: inlines)
                .multilineTextAlignment(alignment.textAlignment)
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        case let .heading(text, level):
            Text(text)
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundStyle(ShellTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .image(url, alt, hidden):
            UBBImage(url: url, alt: alt, hidden: hidden)
        case let .quote(blocks):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(ShellTheme.accent.opacity(0.4))
                    .frame(width: 3)
                AnyView(UBBBlocksView(blocks: blocks))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(ShellTheme.primaryText)
                    .padding(10)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
        case .divider:
            Divider().overlay(ShellTheme.separator)
        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(ShellTheme.accent)
                        Text(items[index])
                            .font(ShellTheme.Fonts.body)
                            .foregroundStyle(ShellTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .table(rows):
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        HStack(spacing: 0) {
                            ForEach(rows[rowIndex].indices, id: \.self) { cellIndex in
                                Text(rows[rowIndex][cellIndex])
                                    .font(ShellTheme.Fonts.footnote)
                                    .foregroundStyle(ShellTheme.primaryText)
                                    .frame(minWidth: 80, alignment: .leading)
                                    .padding(6)
                            }
                        }
                        .background(rowIndex == 0 ? ShellTheme.secondarySurface : ShellTheme.surface)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ShellTheme.separator, lineWidth: 0.5))
        case let .media(title, url):
            if let url {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.rectangle")
                        Text(title.isEmpty ? url.absoluteString : title)
                            .lineLimit(2)
                    }
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.link)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
                }
            } else if !title.isEmpty {
                Text(title)
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 28
        case 2: return 24
        case 3: return 21
        case 4: return 19
        case 5: return 17
        default: return 16
        }
    }
}

struct UBBInlineText: View {
    let inlines: [UBBInline]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        composed
            .font(ShellTheme.Fonts.body)
            .foregroundStyle(ShellTheme.primaryText)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var composed: Text {
        inlines.reduce(Text("")) { result, inline in
            switch inline {
            case let .text(attributed):
                return result + Text(attributed)
            case let .emotion(id):
                if let image = UBBEmotion.image(id, light: colorScheme == .dark) {
                    return result + Text(Image(uiImage: image))
                }
                return result + Text("🙂")
            }
        }
    }
}

struct UBBImage: View {
    let url: URL?
    let alt: String?
    var hidden: Bool = false

    @Environment(\.ubbGallery) private var gallery
    @State private var showViewer = false
    @State private var image: UIImage? = nil
    @State private var imageFailed = false
    private static let imageCache = NSCache<NSURL, UIImage>()

    private var resolvedGallery: [URL] {
        guard let url else { return gallery }
        return gallery.contains(url) ? gallery : [url]
    }

    private var initialIndex: Int {
        guard let url, let index = resolvedGallery.firstIndex(of: url) else { return 0 }
        return index
    }

    var body: some View {
        if let url {
            Group {
                if hidden {
                    VStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .font(.title3)
                        Text("隐藏图片，点击查看")
                    }
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ShellTheme.separator, lineWidth: 0.5)
                    )
                } else if let image {
                    constrainedImage(image)
                } else if imageFailed {
                    failure
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .contentShape(Rectangle())
            .task(id: url) { await loadImage() }
            .onTapGesture { showViewer = true }
            .accessibilityLabel(alt?.isEmpty == false ? alt! : "图片")
            .accessibilityHint(hidden ? "查看隐藏图片" : "查看大图")
            .fullScreenCover(isPresented: $showViewer) {
                NativeImageViewer(urls: resolvedGallery, initialIndex: initialIndex, alt: alt)
            }
        } else {
            failure
        }
    }

    private func constrainedImage(_ image: UIImage) -> some View {
        let ratio = max(0.05, image.size.width / max(1, image.size.height))
        return GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: width, height: max(1, width / ratio))
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ShellTheme.separator, lineWidth: 0.5))
    }

    @MainActor
    private func loadImage() async {
        guard !hidden, image == nil, !imageFailed, let url else { return }
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                throw URLError(.badServerResponse)
            }
            guard let decoded = Self.decode(data) else {
                throw URLError(.cannotDecodeContentData)
            }
            Self.imageCache.setObject(decoded, forKey: url as NSURL)
            image = decoded
        } catch {
            imageFailed = true
        }
    }

    private static func decode(_ data: Data) -> UIImage? {
        if let image = UIImage(data: data) {
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private var failure: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.title3)
                .foregroundStyle(ShellTheme.secondaryText)
            Text(alt?.isEmpty == false ? alt! : "图片无法显示")
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NativeImageViewer: View {
    let urls: [URL]
    let alt: String?

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var saveMessage: String? = nil
    @State private var showSaveMessage = false

    init(urls: [URL], initialIndex: Int, alt: String?) {
        self.urls = urls
        self.alt = alt
        let upper = max(0, urls.count - 1)
        _index = State(initialValue: max(0, min(initialIndex, upper)))
    }

    private var currentURL: URL? {
        urls.indices.contains(index) ? urls[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(urls.indices, id: \.self) { itemIndex in
                    ZoomableImage(url: urls[itemIndex], alt: alt)
                        .tag(itemIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                HStack {
                    Text(urls.isEmpty ? "" : "\(index + 1) / \(urls.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                Spacer()
                HStack(spacing: 14) {
                    if let currentURL {
                        ShareLink(item: currentURL) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3.weight(.semibold))
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    Button {
                        Task { await saveCurrent() }
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.title3.weight(.semibold))
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
            }
            .padding(16)
            .foregroundStyle(.white)
        }
        .statusBarHidden()
        .alert("图片", isPresented: $showSaveMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveMessage ?? "")
        }
    }

    @MainActor
    private func saveCurrent() async {
        guard let currentURL else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: currentURL)
            guard let image = UIImage(data: data) else {
                throw NSError(domain: "CC98Reborn", code: 2, userInfo: [NSLocalizedDescriptionKey: "图片数据无法识别。"])
            }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            saveMessage = "已保存到相册。"
        } catch {
            saveMessage = "保存失败：\(error.localizedDescription)"
        }
        showSaveMessage = true
    }
}

private struct ZoomableImage: View {
    let url: URL
    let alt: String?

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .accessibilityLabel(alt?.isEmpty == false ? alt! : "图片")
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                scale = min(max(baseScale * value.magnification, 1), 5)
                            }
                            .onEnded { _ in
                                baseScale = scale
                                if scale <= 1.01 {
                                    reset()
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1.01 else { return }
                                offset = CGSize(
                                    width: baseOffset.width + value.translation.width,
                                    height: baseOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in baseOffset = offset }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if scale > 1.01 {
                                reset()
                            } else {
                                scale = 2
                                baseScale = 2
                            }
                        }
                    }
            case .failure:
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                    Text("图片加载失败")
                        .font(.subheadline)
                    Text(url.absoluteString)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .foregroundStyle(.white)
            case .empty:
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            @unknown default:
                EmptyView()
            }
        }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}
enum UBBFirstImage {
    static func first(in source: String) -> URL? {
        guard !source.isEmpty else { return nil }
        let patterns: [(String, Int, Int?)] = [
            ("\\[img(?:=([^\\]]*))?\\](.*?)\\[/img\\]", 2, 1),
            ("!\\[[^\\]]*\\]\\(([^\\)]+)\\)", 1, nil),
            ("(?i)<img[^>]+src=[\"']([^\"']+)[\"']", 1, nil)
        ]

        var earliest: (location: Int, raw: String)?
        for (pattern, urlGroup, attributeGroup) in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ) else { continue }
            let ns = source as NSString
            guard let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else {
                continue
            }
            if let attributeGroup, attributeGroup <= regex.numberOfCaptureGroups {
                let attributeRange = match.range(at: attributeGroup)
                if attributeRange.location != NSNotFound {
                    let attribute = ns.substring(with: attributeRange)
                    if attribute.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                        continue
                    }
                }
            }
            guard urlGroup <= regex.numberOfCaptureGroups else { continue }
            let range = match.range(at: urlGroup)
            guard range.location != NSNotFound else { continue }
            let raw = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            if earliest == nil || match.range.location < earliest!.location {
                earliest = (match.range.location, raw)
            }
        }

        guard let raw = earliest?.raw else { return nil }
        return resolve(raw)
    }

    private static func resolve(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        if value.hasPrefix("/") { value = "https://www.cc98.org" + value }
        if !value.contains("://") { value = "https://www.cc98.org/" + value }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}

enum UBBEmotion {
    private struct Asset {
        let folder: String
        let name: String
        let extensions: [String]
    }

    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ tag: String, light: Bool = false, maxSide: CGFloat = 60) -> UIImage? {
        let key = "\(tag.lowercased())|\(light ? "light" : "dark")|\(Int(maxSide))"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let asset = resolve(tag.lowercased(), light: light), let image = load(asset) else { return nil }
        let scaled = resize(image, maxSide: maxSide)
        cache.setObject(scaled, forKey: key as NSString)
        return scaled
    }

    private static func resolve(_ tag: String, light: Bool) -> Asset? {
        if tag.hasPrefix("cc98") {
            let id = String(tag.dropFirst(4))
            guard isNumeric(id) else { return nil }
            return Asset(folder: "CC98", name: "CC98" + id, extensions: ["png", "gif"])
        }
        if tag.hasPrefix("ac") {
            let id = String(tag.dropFirst(2))
            guard isNumeric(id) else { return nil }
            return Asset(folder: light ? "ac1" : "ac", name: id, extensions: ["png"])
        }
        if tag.hasPrefix("em") {
            let id = String(tag.dropFirst(2))
            guard isNumeric(id) else { return nil }
            return Asset(folder: "em", name: "em" + id, extensions: ["gif", "png"])
        }
        if tag.hasPrefix("ms") {
            let id = String(tag.dropFirst(2))
            guard isNumeric(id) else { return nil }
            return Asset(folder: "ms", name: "ms" + id, extensions: ["png", "gif"])
        }
        if tag.hasPrefix("tb") {
            let id = String(tag.dropFirst(2))
            guard isNumeric(id) else { return nil }
            return Asset(folder: "tb", name: "tb" + id, extensions: ["png", "gif"])
        }
        return nil
    }

    private static func load(_ asset: Asset) -> UIImage? {
        let folders = asset.folder == "ac1" ? ["ac1", "ac"] : [asset.folder]
        for folder in folders {
            for ext in asset.extensions {
                if let url = Bundle.main.url(
                    forResource: asset.name,
                    withExtension: ext,
                    subdirectory: "Reborn/images/\(folder)"
                ), let image = UIImage(contentsOfFile: url.path) {
                    return image
                }
            }
        }
        return nil
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isNumber }
    }

    private static func resize(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let ratio = min(maxSide / size.width, maxSide / size.height)
        let target = CGSize(
            width: max(1, (size.width * ratio).rounded()),
            height: max(1, (size.height * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
enum UBBBlockParser {
    private struct Tag {
        let name: String
        let value: String?
        let closing: Bool
        let range: Range<String.Index>
    }

    private static let blockTags: Set<String> = [
        "quote", "code", "math", "md", "no-ubb", "list", "table",
        "align", "center", "left", "right", "bili", "audio", "video",
        "img", "hr", "line"
    ]

    private static let nestedTags: Set<String> = ["quote", "code", "math", "md", "no-ubb", "list", "table", "align", "center", "left", "right"]

    static func parse(_ source: String, markdown: Bool) -> [UBBBlock] {
        let decoded = decodeEntities(source)
        if markdown, !looksLikeUBB(decoded) {
            return NativeMarkdownRenderer.parse(decoded)
        }
        return parseBlocks(expandBareImages(normalizeImplicitLinks(decoded)))
    }

    private static func normalizeImplicitLinks(_ source: String) -> String {
        var value = source
        let replacements: [(String, String)] = [
            ("\\[url\\]\\s*(https?://[^\\[\\]\\s]+|www\\.[^\\[\\]\\s]+|/[^\\[\\]\\s]+)\\s*\\[/url\\]", "[url=$1]$1[/url]"),
            ("\\[email\\]\\s*([^\\[\\]\\s]+@[^\\[\\]\\s]+)\\s*\\[/email\\]", "[email=$1]$1[/email]")
        ]
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = value as NSString
            value = regex.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: template
            )
        }
        return value
    }

    private static func expandBareImages(_ source: String) -> String {
        var value = source

        // CC98 sometimes emits images as literal [图片] path/to/file.webp [图片]
        // markers rather than an [img] tag.
        let markedImagePatterns = [
            "(?i)\\[图片\\]\\s*([^\\s\\[\\]]+?\\.(?:png|jpe?g|gif|webp)(?:\\?[^\\s\\[\\]]*)?)\\s*(?:\\[图片\\])?",
            "(?i)【图片】\\s*([^\\s【】]+?\\.(?:png|jpe?g|gif|webp)(?:\\?[^\\s【】]*)?)\\s*(?:【图片】)?"
        ]
        for pattern in markedImagePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = value as NSString
            value = regex.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: "[img]$1[/img]"
            )
        }

        if let regex = try? NSRegularExpression(pattern: "(?i)<img[^>]+src=[\"']([^\"']+)[\"'][^>]*>") {
            let ns = value as NSString
            value = regex.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: "[img]$1[/img]"
            )
        }

        if let regex = try? NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(([^\\)]+)\\)") {
            let ns = value as NSString
            value = regex.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: "[img]$1[/img]"
            )
        }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
        let punctuation = CharacterSet(charactersIn: "。，；：！？）】、,;:!?)]}")
        return value.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("http") else { return line }
            let candidate = trimmed.trimmingCharacters(in: punctuation)
            guard let url = URL(string: candidate),
                  imageExtensions.contains(url.pathExtension.lowercased()) else {
                return line
            }
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            return String(indentation) + "[img]\(candidate)[/img]"
        }
        .joined(separator: "\n")
    }

    // MARK: Blocks

    private static func parseBlocks(_ source: String) -> [UBBBlock] {
        var blocks: [UBBBlock] = []
        var pending = ""
        var index = source.startIndex

        while index < source.endIndex {
            guard source[index] == "[", let tag = readTag(source, at: index) else {
                pending.append(source[index])
                index = source.index(after: index)
                continue
            }

            guard !tag.closing else {
                pending += source[index..<tag.range.upperBound]
                index = tag.range.upperBound
                continue
            }

            guard blockTags.contains(tag.name) else {
                pending += source[index..<tag.range.upperBound]
                index = tag.range.upperBound
                continue
            }

            if !pending.isEmpty {
                appendText(pending, to: &blocks)
                pending = ""
            }

            if tag.name == "hr" || tag.name == "line" {
                blocks.append(.divider)
                index = tag.range.upperBound
                continue
            }

            if tag.name == "img" {
                if let close = findClose("img", in: source, after: tag.range.upperBound) {
                    let content = String(source[tag.range.upperBound..<close.lowerBound])
                    let rawURL = (tag.value.flatMap { isRemoteURL($0) ? $0 : nil }) ?? content
                    let alt = tag.value.flatMap { isRemoteURL($0) ? nil : ($0 == "1" ? nil : $0) }
                    let hidden = tag.value == "1"
                    blocks.append(.image(resolveURL(rawURL), alt, hidden))
                    index = close.upperBound
                } else {
                    blocks.append(.image(tag.value.flatMap(resolveURL), nil, false))
                    index = tag.range.upperBound
                }
                continue
            }

            guard let close = findClose(tag.name, in: source, after: tag.range.upperBound) else {
                pending += source[index..<tag.range.upperBound]
                index = tag.range.upperBound
                continue
            }

            let content = String(source[tag.range.upperBound..<close.lowerBound])
            switch tag.name {
            case "quote":
                blocks.append(.quote(parseBlocks(content)))
            case "code":
                blocks.append(.code(trimNewlines(content)))
            case "math":
                blocks.append(.code(trimNewlines(content)))
            case "md":
                blocks.append(contentsOf: NativeMarkdownRenderer.parse(content))
            case "no-ubb":
                blocks.append(.text([.text(AttributedString(cleanText(content)))], .leading))
            case "list":
                blocks.append(.list(parseList(content)))
            case "table":
                blocks.append(.table(parseTable(content)))
            case "align", "center", "left", "right":
                let requested = tag.value?.lowercased() ?? tag.name
                let alignment: UBBAlignment
                switch requested {
                case "center":
                    alignment = .center
                case "right", "trailing":
                    alignment = .trailing
                default:
                    alignment = .leading
                }
                blocks.append(.text(parseInline(content), alignment))
            case "bili":
                let identifier = trimNewlines(content).trimmingCharacters(in: .whitespacesAndNewlines)
                let biliURL = identifier.hasPrefix("http")
                    ? URL(string: identifier)
                    : URL(string: "https://www.bilibili.com/video/" + identifier)
                blocks.append(.media("Bilibili 视频", biliURL))
            case "audio", "video":
                blocks.append(.media(trimNewlines(content), resolveURL(content)))
            default:
                appendText(content, to: &blocks)
            }
            index = close.upperBound
        }

        if !pending.isEmpty {
            appendText(pending, to: &blocks)
        }
        return blocks
    }

    private static func appendText(_ raw: String, to blocks: inout [UBBBlock]) {
        let trimmed = trimNewlines(raw)
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let inlines = parseInline(trimmed)
        if !inlines.isEmpty {
            blocks.append(.text(inlines, .leading))
        }
    }

    // MARK: Inline

    private static func parseInline(_ source: String) -> [UBBInline] {
        var parser = InlineParser()
        return parser.parse(source)
    }

    private struct InlineParser {
        private var bold = 0
        private var italic = 0
        private var underline = 0
        private var strike = 0
        private var code = 0
        private var link: URL?
        private var color: Color?
        private var size: CGFloat?
        private var result: [UBBInline] = []
        private var buffer = AttributedString()

        mutating func parse(_ source: String) -> [UBBInline] {
            var index = source.startIndex
            var cursor = index
            while index < source.endIndex {
                guard source[index] == "[", let tag = UBBBlockParser.readTag(source, at: index) else {
                    index = source.index(after: index)
                    continue
                }
                if tag.range.lowerBound > cursor {
                    append(String(source[cursor..<tag.range.lowerBound]))
                }
                handle(tag)
                cursor = tag.range.upperBound
                index = tag.range.upperBound
            }
            if cursor < source.endIndex {
                append(String(source[cursor...]))
            }
            flush()
            return result
        }

        private mutating func handle(_ tag: UBBBlockParser.Tag) {
            switch tag.name {
            case "b": bold = max(0, bold + (tag.closing ? -1 : 1))
            case "i", "em": italic = max(0, italic + (tag.closing ? -1 : 1))
            case "u": underline = max(0, underline + (tag.closing ? -1 : 1))
            case "del": strike = max(0, strike + (tag.closing ? -1 : 1))
            case "code": code = max(0, code + (tag.closing ? -1 : 1))
            case "url", "email":
                if tag.closing {
                    link = nil
                } else if let value = tag.value {
                    link = tag.name == "email" ? URL(string: "mailto:" + value) : UBBBlockParser.resolveURL(value)
                }
            case "color":
                if tag.closing {
                    color = nil
                } else if let value = tag.value {
                    color = UBBBlockParser.colorFrom(value)
                }
            case "size":
                if tag.closing {
                    size = nil
                } else if let value = tag.value, let number = Int(value) {
                    size = UBBBlockParser.fontSize(number)
                }
            case "br":
                append("\n")
            case "hr", "line":
                append("\n———\n")
            case "img":
                flush()
                result.append(.text(AttributedString("［图片］")))
            default:
                if !tag.closing, UBBBlockParser.isEmotionTag(tag.name) {
                    flush()
                    result.append(.emotion(tag.name))
                }
            }
        }

        private mutating func append(_ raw: String) {
            let text = UBBBlockParser.cleanText(raw)
            guard !text.isEmpty else { return }

            if let link {
                appendRun(text, link: link)
            } else if code > 0 {
                appendRun(text, link: nil)
            } else {
                for segment in UBBBlockParser.splitLinks(text) {
                    appendRun(segment.text, link: segment.url)
                }
            }
        }

        private mutating func appendRun(_ text: String, link: URL?) {
            guard !text.isEmpty else { return }
            var container = AttributeContainer()
            var font = Font.body
            if let size { font = .system(size: size) }
            if bold > 0 { font = font.bold() }
            if italic > 0 { font = font.italic() }
            if code > 0 { font = .system(size: size ?? 15, design: .monospaced) }
            if bold > 0 || italic > 0 || code > 0 || size != nil { container.font = font }
            if underline > 0 { container.underlineStyle = Text.LineStyle.single }
            if strike > 0 { container.strikethroughStyle = Text.LineStyle.single }
            if let link { container.link = link }
            if let color { container.foregroundColor = color }
            var run = AttributedString(text)
            run.setAttributes(container)
            buffer.append(run)
        }

        private mutating func flush() {
            guard !buffer.characters.isEmpty else { return }
            result.append(.text(buffer))
            buffer = AttributedString()
        }
    }

    // MARK: Lists, tables, media

    static func splitLinks(_ text: String) -> [(text: String, url: URL?)] {
        guard !text.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)(https?://[^\\s<>\"']+|www\\.[^\\s<>\"']+|(?:[a-z0-9-]+\\.)*cc98\\.org/[^\\s<>\"']+)"
        ) else {
            return [(text, nil)]
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [(text, nil)] }

        var result: [(text: String, url: URL?)] = []
        var cursor = 0
        let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}，。；：！？）】、")

        for match in matches {
            if match.range.location > cursor {
                result.append((ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), nil))
            }
            var raw = ns.substring(with: match.range)
            var trailing = ""
            while let scalar = raw.unicodeScalars.last, trailingPunctuation.contains(scalar) {
                trailing = String(scalar) + trailing
                raw.removeLast()
            }
            guard !raw.isEmpty else {
                if !trailing.isEmpty { result.append((trailing, nil)) }
                cursor = match.range.location + match.range.length
                continue
            }

            var urlString = raw
            if !urlString.contains("://") {
                urlString = "https://" + urlString
            }
            result.append((raw, URL(string: urlString)))
            if !trailing.isEmpty {
                result.append((trailing, nil))
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < ns.length {
            result.append((ns.substring(from: cursor), nil))
        }
        return result
    }

    private static func parseList(_ content: String) -> [String] {
        let sentinel = "\u{1F}"
        let replaced = content.replacingOccurrences(of: "[*]", with: sentinel, options: .caseInsensitive)
        let parts = replaced.split(separator: Character(sentinel))
        if parts.count > 1 {
            return parts.map { plainText(String($0)) }.filter { !$0.isEmpty }
        }
        return content.split(separator: "\n").map { plainText(String($0)) }.filter { !$0.isEmpty }
    }

    private static func parseTable(_ content: String) -> [[String]] {
        guard let rowRegex = try? NSRegularExpression(pattern: "(?is)\\[tr\\](.*?)\\[/tr\\]"),
              let cellRegex = try? NSRegularExpression(pattern: "(?is)\\[(td|th)(?:=[^\\]]*)?\\](.*?)\\[/\\1\\]") else {
            return [[plainText(content)]]
        }
        let ns = content as NSString
        var rows: [[String]] = []
        for rowMatch in rowRegex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let rowText = ns.substring(with: rowMatch.range(at: 1))
            let rowNS = rowText as NSString
            let cells = cellRegex.matches(in: rowText, range: NSRange(location: 0, length: rowNS.length)).map {
                plainText(rowNS.substring(with: $0.range(at: 2)))
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        if rows.isEmpty {
            return content.split(separator: "\n").map { [plainText(String($0))] }
        }
        return rows
    }

    // MARK: Helpers

    private static func plainText(_ raw: String) -> String {
        let inlines = parseInline(raw)
        var value = ""
        for inline in inlines {
            switch inline {
            case let .text(attributed): value += String(attributed.characters)
            case .emotion: value += "🙂"
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readTag(_ source: String, at index: String.Index) -> Tag? {
        guard index < source.endIndex, source[index] == "[" else { return nil }
        guard let close = source[index...].firstIndex(of: "]") else { return nil }
        var inner = String(source[source.index(after: index)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty, inner.count <= 200 else { return nil }
        var closing = false
        if inner.hasPrefix("/") {
            closing = true
            inner.removeFirst()
            inner = inner.trimmingCharacters(in: .whitespaces)
        }
        let parts = inner.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let name = String(first).trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, name.count <= 40, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "*" || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        return Tag(name: name, value: value, closing: closing, range: index..<source.index(after: close))
    }

    private static func findClose(_ name: String, in source: String, after start: String.Index) -> Range<String.Index>? {
        var index = start
        var depth = 1
        while index < source.endIndex {
            guard source[index] == "[", let tag = readTag(source, at: index) else {
                index = source.index(after: index)
                continue
            }
            if tag.name == name {
                if tag.closing {
                    depth -= 1
                    if depth == 0 { return tag.range }
                } else if nestedTags.contains(name) {
                    depth += 1
                }
            }
            index = tag.range.upperBound
        }
        return nil
    }

    static func isEmotionTag(_ name: String) -> Bool {
        let prefixes = ["cc98", "ac", "em", "ms", "tb"]
        guard let prefix = prefixes.first(where: { name.hasPrefix($0) }),
              name.count > prefix.count else { return false }
        return name.dropFirst(prefix.count).allSatisfy { $0.isNumber }
    }

    private static func looksLikeUBB(_ text: String) -> Bool {
        text.range(
            of: "(?i)\\[/?\\s*(b|i|u|del|quote|code|img|url|email|color|size|font|align|center|left|right|list|table|cc98\\d{1,2}|ac\\d{2,4}|em\\d{2}|ms\\d{2}|tb\\d{2})\\b",
            options: .regularExpression
        ) != nil
    }

    private static func isRemoteURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("//") || trimmed.hasPrefix("/")
    }

    static func resolveURL(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("//") { value = "https:" + value }
        if value.hasPrefix("/") { value = "https://www.cc98.org" + value }
        if !value.contains("://") { value = "https://www.cc98.org/" + value }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private static func colorFrom(_ raw: String) -> Color? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "gray", "grey": return .gray
        case "white": return .white
        case "black": return .black
        default: return Color(ubbColor: value)
        }
    }

    private static func fontSize(_ number: Int) -> CGFloat {
        let sizes: [CGFloat] = [12, 14, 17, 20, 23, 26, 30]
        return sizes[min(max(number - 1, 0), sizes.count - 1)]
    }

    private static func trimNewlines(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.newlines)
    }

    static func decodeEntities(_ source: String) -> String {
        var value = decodeNumericEntities(source)
        value = value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
        return value
    }

    private static func decodeNumericEntities(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]{1,7});") else { return source }
        let ns = source as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let hexadecimal = ns.substring(with: match.range(at: 1)).lowercased() == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: hexadecimal ? 16 : 10), let scalar = UnicodeScalar(code) {
                result.unicodeScalars.append(scalar)
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { result += ns.substring(from: cursor) }
        return result
    }

    static func cleanText(_ raw: String) -> String {
        var value = decodeEntities(raw)
        value = value.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?i)</p\\s*>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return value
    }
}

private extension Color {
    init?(ubbColor raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 3, let number = UInt32(value, radix: 16) else { return nil }
        let red: UInt32
        let green: UInt32
        let blue: UInt32
        if value.count == 6 {
            red = (number >> 16) & 0xFF
            green = (number >> 8) & 0xFF
            blue = number & 0xFF
        } else {
            let r = (number >> 8) & 0xF
            let g = (number >> 4) & 0xF
            let b = number & 0xF
            red = r * 17; green = g * 17; blue = b * 17
        }
        self.init(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1)
    }
}
