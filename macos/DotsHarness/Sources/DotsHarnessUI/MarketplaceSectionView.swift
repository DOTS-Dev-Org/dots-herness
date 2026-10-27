// Copyright (c) 2026 DOTS
// Marketplace section: plugins, skills and project starters in one place.

import AppKit
import SwiftUI
import DotsHarnessCore

struct MarketplaceSectionView: View {
    private enum Tab: String, CaseIterable {
        case plugins, skills, starters
        var title: String { AppCopy.text("market.tab.\(rawValue)") }
        var systemImage: String {
            switch self {
            case .plugins: return "puzzlepiece.extension"
            case .skills: return "cube"
            case .starters: return "square.grid.2x2"
            }
        }
    }

    @ObservedObject var model: AppModel
    @State private var tab: Tab = .plugins

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppCopy.text("marketplace.title"))
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                ForEach(Tab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Label(item.title, systemImage: item.systemImage)
                            .font(.system(size: 13, weight: tab == item ? .medium : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(tab == item ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                InstalledPluginsList(market: model.marketplace)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .frame(width: 230)

            Divider()

            Group {
                switch tab {
                case .plugins: MarketplaceView(model: model)
                case .skills: SkillsSettingsView(model: model)
                case .starters: ProjectStartersView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Sidebar list of marketplace plugins that are installed locally.
private struct InstalledPluginsList: View {
    @ObservedObject var market: MarketplaceClient

    var body: some View {
        let installed = (market.entries + market.communityEntries).filter {
            if case .notInstalled = market.status($0) { return false }
            return true
        }
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.text("local.installed")).font(.system(size: 13, weight: .medium))
            if installed.isEmpty {
                Text(AppCopy.text("market.noInstalled"))
            } else {
                ForEach(installed) { Text($0.name).lineLimit(1) }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 22)
    }
}

/// A project scaffold: a folder the user picks plus a first message that builds it.
struct ProjectStarter: Identifiable {
    let id: String
    let systemImage: String
    let category: String
    /// Sent to the agent as written; the model reads English regardless of interface language.
    let prompt: String
    /// Catalog copy for starters this build has no translation for.
    var remoteTitle: String?
    var remoteDetail: String?
    var downloads: Int?
    var likes: Int?
    var featured = false

    var title: String { localized("title") ?? remoteTitle ?? id }
    var detail: String { localized("detail") ?? remoteDetail ?? "" }
    var item: MarketItem {
        MarketItem(id: id, symbol: systemImage, title: title, summary: detail, category: category, publisher: "DOTS", badge: .official,
                   downloads: downloads, likes: likes, featured: featured)
    }

    private func localized(_ field: String) -> String? {
        let key = "starters.\(id).\(field)"
        let text = AppCopy.text(key)
        return text == key ? nil : text
    }

    init(id: String, systemImage: String, category: String, prompt: String) {
        self.id = id
        self.systemImage = systemImage
        self.category = category
        self.prompt = prompt
    }

    init(_ remote: MarketStarter) {
        self.init(id: remote.id, systemImage: remote.systemImage ?? "square.grid.2x2", category: remote.category ?? "other", prompt: remote.prompt)
        remoteTitle = remote.title
        remoteDetail = remote.detail
        downloads = remote.downloads
        likes = remote.likes
        featured = remote.featured ?? false
    }

    /// Shipped copy of the catalog, shown only until the first successful fetch.
    static let all: [ProjectStarter] = [
        ProjectStarter(id: "web", systemImage: "globe", category: "web", prompt: """
        Scaffold a Next.js (App Router, TypeScript) web app in this empty folder: a home page, a shared layout, \
        one example API route, ESLint, and a README with run commands. Install dependencies and confirm it builds.
        """),
        ProjectStarter(id: "landing", systemImage: "doc.richtext", category: "web", prompt: """
        Scaffold a static landing page in this empty folder with plain HTML, CSS and a little JavaScript, no build step: \
        hero, features, pricing and contact sections, responsive down to phone width. Add a README on how to preview it.
        """),
        ProjectStarter(id: "api", systemImage: "server.rack", category: "backend", prompt: """
        Scaffold a FastAPI service in this empty folder: a health endpoint, one example CRUD resource with Pydantic models, \
        settings from environment variables, pytest tests, and a README with run commands. Verify the tests pass.
        """),
        ProjectStarter(id: "ios", systemImage: "iphone", category: "mobile", prompt: """
        Scaffold a SwiftUI iOS app in this empty folder as a Swift package plus an XcodeGen project.yml: a tab view with \
        two example screens, an observable model, and one unit test. Add a README on how to generate and run the project.
        """),
        ProjectStarter(id: "worker", systemImage: "cloud", category: "backend", prompt: """
        Scaffold a Cloudflare Worker (TypeScript) in this empty folder with wrangler: a JSON API with two routes, \
        typed environment bindings, a vitest test, and a README covering local dev and deploy.
        """),
        ProjectStarter(id: "cli", systemImage: "terminal", category: "tools", prompt: """
        Scaffold a Python command-line tool in this empty folder with a pyproject.toml: an argparse entry point with two \
        subcommands, a tests folder with pytest, and a README with install and usage. Verify the tests pass.
        """),
    ]
}

private struct ProjectStartersView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var market: MarketplaceClient
    @State private var detailID: String?
    @State private var error = ""

    init(model: AppModel) {
        self.model = model
        self.market = model.marketplace
    }

    private var starters: [ProjectStarter] {
        market.starters.isEmpty ? ProjectStarter.all : market.starters.map(ProjectStarter.init)
    }
    private var items: [MarketItem] { starters.map(\.item) }

    var body: some View {
        content.task {
            await market.refreshStarters()
            await market.refreshLikes()
        }
    }

    private func likeButton(_ starter: ProjectStarter) -> some View {
        let signedIn = market.session.isSignedIn
        let liked = market.likedCatalog["starter"]?.contains(starter.id) ?? false
        return MarketIconButton(liked ? "heart.fill" : "heart",
                                help: AppCopy.text(signedIn ? (liked ? "market.unlike" : "market.like") : "market.likeSignIn")) {
            error = ""
            Task {
                do { try await market.setCatalogLiked(!liked, kind: "starter", id: starter.id) }
                catch { self.error = error.localizedDescription }
            }
        }
        // The shipped fallback list has no server row to like.
        .disabled(!signedIn || market.starters.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if let starter = starters.first(where: { $0.id == detailID }) {
            MarketDetail(item: starter.item, backTitle: AppCopy.text("market.tab.starters"), back: { detailID = nil },
                         related: starter.item.related(in: items, limit: 2), openRelated: { detailID = $0.id }) {
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                Text(starter.detail).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppCopy.text("market.starter.prompt")).font(.headline)
                    Text(starter.prompt)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Text(AppCopy.text("starters.chooseFolder")).font(.caption).foregroundStyle(.secondary)
            } actions: {
                likeButton(starter)
                Button(AppCopy.text("starters.use")) { use(starter) }.buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(AppCopy.text("market.tab.starters")).font(.system(size: 24, weight: .semibold))
                    Text(AppCopy.text("starters.intro")).font(.callout).foregroundStyle(.secondary)
                    MarketFeatured(items: MarketItem.featured(in: items)) { detailID = $0.id }
                    ForEach(MarketItem.sections(items), id: \.title) { section in
                        Text(section.title).font(.system(size: 16, weight: .medium)).padding(.top, 10)
                        LazyVGrid(columns: MarketRowLayout.columns, alignment: .leading, spacing: 20) {
                            ForEach(section.items) { item in
                                MarketRow(item: item, open: { detailID = item.id }) {
                                    MarketIconButton("plus", help: AppCopy.text("starters.use")) {
                                        if let starter = starters.first(where: { $0.id == item.id }) { use(starter) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Opens the chosen folder as a project and leaves the starter prompt in the
    /// composer, so the user reads it before anything is written.
    private func use(_ starter: ProjectStarter) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = AppCopy.text("starters.use")
        panel.message = AppCopy.text("starters.chooseFolder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await market.recordCatalogDownload(kind: "starter", id: starter.id) }
        model.setWorkspace(url.path)
        model.newConversation()
        model.draft = starter.prompt
        model.open(.home)
    }
}

// MARK: - Shared marketplace pieces (plugins, skills, starters)

enum MarketRowLayout {
    static let columns = [GridItem(.adaptive(minimum: 300), spacing: 32)]
}

enum MarketCategory {
    /// Titles live in the catalog as market.category.<id>.
    private static let table: [String: (symbol: String, tint: Color)] = [
        "coding": ("chevron.left.forwardslash.chevron.right", .blue),
        "git": ("arrow.triangle.branch", .orange),
        "qa": ("checkmark.seal", .green),
        "devops": ("server.rack", .teal),
        "browser": ("globe", .indigo),
        "web": ("globe", .indigo),
        "backend": ("server.rack", .teal),
        "mobile": ("iphone", .blue),
        "models": ("cpu", .purple),
        "integrations": ("link", .cyan),
        "workspace": ("folder", .brown),
        "productivity": ("bolt", .yellow),
        "tools": ("terminal", .gray),
        "design": ("paintbrush", .pink),
        "documents": ("doc.richtext", .orange),
        "authoring": ("square.and.pencil", .purple),
        "community": ("person.2", .mint),
        // Local model shelves.
        "chat": ("bubble.left.and.bubble.right", .blue),
        "image": ("photo", .pink),
        "modeling": ("cube.transparent", .orange),
        "video": ("film", .red),
        "audio": ("waveform", .green),
    ]
    /// Section and filter order; anything the table doesn't know lands in "other", last.
    private static let order = [
        "coding", "git", "qa", "devops", "browser", "web", "backend", "mobile", "models",
        "integrations", "workspace", "productivity", "tools", "design", "documents", "authoring", "community",
        "chat", "image", "modeling", "video", "audio",
    ]

    /// Normalized id: registry spelling varies in case, and unknown ids share one bucket.
    static func key(_ id: String) -> String { table[id.lowercased()] == nil ? "other" : id.lowercased() }
    static func rank(_ id: String) -> Int { order.firstIndex(of: key(id)) ?? order.count }
    static func title(_ id: String) -> String { AppCopy.text("market.category.\(key(id))") }
    static func symbol(_ id: String, fallback: String = "puzzlepiece.extension") -> String { table[id.lowercased()]?.symbol ?? fallback }
    static func tint(_ id: String) -> Color { table[id.lowercased()]?.tint ?? .gray }
}

enum MarketBadge: String {
    case official, verified

    var title: String { AppCopy.text(self == .official ? "market.badge.official" : "market.badge.verified") }
    var symbol: String { self == .official ? "checkmark.seal.fill" : "checkmark.shield.fill" }
    var tint: Color { self == .official ? .blue : .green }
}

/// What every marketplace listing shows, whatever it is underneath.
struct MarketItem: Identifiable {
    let id: String
    var symbol: String
    var title: String
    var summary: String
    var category = "other"
    var publisher = ""
    var badge: MarketBadge?
    /// ISO date or timestamp; only the day is shown.
    var date: String?
    var downloads: Int?
    var likes: Int?
    var featured = false

    var formattedDate: String? {
        guard let date else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: String(date.prefix(10)))?.formatted(date: .abbreviated, time: .omitted)
    }

    static func count(_ value: Int?) -> String {
        value.map { $0.formatted(.number.notation(.compactName)) } ?? "—"
    }

    /// Recommendations for the detail page: same category first, then the most downloaded of the rest.
    func related(in all: [MarketItem], limit: Int = 4) -> [MarketItem] {
        let others = all.filter { $0.id != id }
        let rest = others.filter { $0.category != category }.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
        return Array((others.filter { $0.category == category } + rest).prefix(limit))
    }

    /// Banner picks: flagged listings, or the most downloaded when nothing is flagged.
    static func featured(in all: [MarketItem], limit: Int = 5) -> [MarketItem] {
        let flagged = all.filter(\.featured)
        return Array((flagged.isEmpty ? all.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) } : flagged).prefix(limit))
    }

    /// Listings grouped by category, sections in `MarketCategory` order, catalog order within each.
    static func sections(_ all: [MarketItem]) -> [(title: String, items: [MarketItem])] {
        Dictionary(grouping: all) { MarketCategory.key($0.category) }
            .sorted { MarketCategory.rank($0.key) < MarketCategory.rank($1.key) }
            .map { (MarketCategory.title($0.key), $0.value) }
    }
}

private struct MarketIconTile: View {
    let symbol: String
    let size: CGFloat
    let tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size / 4, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.44))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: shape)
            .overlay(shape.stroke(tint.opacity(0.2)))
    }
}

/// Publisher name with its badge; `titled` spells the badge out next to the icon.
private struct MarketPublisher: View {
    let item: MarketItem
    var titled = false

    var body: some View {
        HStack(spacing: 4) {
            if !item.publisher.isEmpty { Text(item.publisher) }
            if let badge = item.badge {
                Image(systemName: badge.symbol).foregroundStyle(badge.tint).help(badge.title)
                if titled { Text(badge.title).foregroundStyle(badge.tint) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MarketStat: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
    }
}

/// Compact catalog row: icon tile, name, one-line summary, metadata line, trailing action. Click opens the detail page.
struct MarketRow<Trailing: View>: View {
    let item: MarketItem
    let open: () -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            MarketIconTile(symbol: item.symbol, size: 40, tint: MarketCategory.tint(item.category))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    Text(MarketCategory.title(item.category))
                    MarketPublisher(item: item)
                    if let downloads = item.downloads { MarketStat(symbol: "arrow.down.circle", text: MarketItem.count(downloads)) }
                    if let likes = item.likes { MarketStat(symbol: "heart", text: MarketItem.count(likes)) }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
    }
}

/// "Önerilenler" carousel: featured listings paged by arrows, dots or dragging; rotates unless hovered.
struct MarketFeatured: View {
    let items: [MarketItem]
    let open: (MarketItem) -> Void
    @State private var index = 0
    @State private var drag: CGFloat = 0
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let height: CGFloat = 200

    var body: some View {
        if !items.isEmpty {
            let current = min(index, items.count - 1)
            let tint = MarketCategory.tint(items[current].category)
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            VStack(alignment: .leading, spacing: 10) {
                Text(AppCopy.text("market.featured")).font(.system(size: 16, weight: .medium))
                GeometryReader { geometry in
                    let width = geometry.size.width
                    HStack(spacing: 0) {
                        ForEach(items) { card($0).frame(width: width, height: Self.height) }
                    }
                    .offset(x: -CGFloat(current) * width + drag)
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                let moved = value.translation.width
                                // Nothing past either end: resist instead of revealing blank space.
                                let atEnd = (current == 0 && moved > 0) || (current == items.count - 1 && moved < 0)
                                drag = atEnd ? moved / 4 : moved
                            }
                            .onEnded { value in
                                let thrown = value.predictedEndTranslation.width
                                let step = thrown < -width / 3 ? 1 : (thrown > width / 3 ? -1 : 0)
                                withAnimation(animation) {
                                    index = min(max(current + step, 0), items.count - 1)
                                    drag = 0
                                }
                            }
                    )
                }
                .frame(height: Self.height)
                .clipShape(shape)
                .overlay(shape.stroke(tint.opacity(0.25)))
                .overlay { if items.count > 1 { controls(current) } }
            }
            .onHover { hovering = $0 }
            .task(id: items.count) {
                guard items.count > 1, !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(6))
                    if Task.isCancelled { break }
                    if !hovering && drag == 0 { go(index + 1) }
                }
            }
        }
    }

    private var animation: Animation? { reduceMotion ? nil : .snappy(duration: 0.35) }

    /// Wraps around, so the arrows never dead-end.
    private func go(_ target: Int) {
        withAnimation(animation) { index = (target % items.count + items.count) % items.count }
    }

    private func card(_ item: MarketItem) -> some View {
        let tint = MarketCategory.tint(item.category)
        return VStack(alignment: .leading, spacing: 8) {
            Label(MarketCategory.title(item.category), systemImage: item.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(tint.opacity(0.16), in: Capsule())
            Text(item.title).font(.system(size: 26, weight: .bold)).lineLimit(1)
            Text(item.summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: 440, alignment: .leading)
            HStack(spacing: 12) {
                MarketPublisher(item: item, titled: true)
                if let downloads = item.downloads { MarketStat(symbol: "arrow.down.circle", text: MarketItem.count(downloads)) }
                if let likes = item.likes { MarketStat(symbol: "heart", text: MarketItem.count(likes)) }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        // Side padding clears the arrows, bottom padding the page dots.
        .padding(.horizontal, 56)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(alignment: .trailing) {
            Image(systemName: item.symbol)
                .font(.system(size: 120, weight: .light))
                .foregroundStyle(tint.opacity(0.28))
                .padding(.trailing, 64)
                .accessibilityHidden(true)
        }
        .background {
            ZStack {
                LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [tint.opacity(0.3), .clear], center: .trailing, startRadius: 0, endRadius: 280)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func controls(_ current: Int) -> some View {
        ZStack(alignment: .bottom) {
            HStack {
                arrow("chevron.left", AppCopy.text("market.previous")) { go(current - 1) }
                Spacer()
                arrow("chevron.right", AppCopy.text("ask.next")) { go(current + 1) }
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)

            HStack(spacing: 5) {
                ForEach(items.indices, id: \.self) { position in
                    Button { go(position) } label: {
                        Capsule()
                            .fill(Color.primary.opacity(position == current ? 0.75 : 0.25))
                            .frame(width: position == current ? 18 : 6, height: 6)
                            .frame(height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(items[position].title)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func arrow(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0.55)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct MarketIconButton: View {
    private let symbol: String
    private let help: String
    private let action: () -> Void

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct MarketPill: View {
    private let title: String
    private let selected: Bool
    private let action: () -> Void

    init(_ title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(selected ? 0.1 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct MarketField: View {
    private let label: String
    private let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// In-page detail shared by every marketplace item: back button, header with actions,
/// metrics strip, the item's own body, then recommendations.
struct MarketDetail<Content: View, Actions: View>: View {
    private let item: MarketItem
    private let backTitle: String
    private let back: () -> Void
    private let related: [MarketItem]
    private let openRelated: (MarketItem) -> Void
    private let content: Content
    private let actions: Actions

    init(item: MarketItem, backTitle: String, back: @escaping () -> Void,
         related: [MarketItem] = [], openRelated: @escaping (MarketItem) -> Void = { _ in },
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.item = item
        self.backTitle = backTitle
        self.back = back
        self.related = related
        self.openRelated = openRelated
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Button(action: back) {
                    Label(backTitle, systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                HStack(alignment: .top, spacing: 16) {
                    MarketIconTile(symbol: item.symbol, size: 72, tint: MarketCategory.tint(item.category))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.system(size: 24, weight: .semibold)).lineLimit(2)
                        MarketPublisher(item: item, titled: true).font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(item.id).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    actions
                }

                HStack(spacing: 0) {
                    stat(AppCopy.text("market.stat.downloads"), MarketItem.count(item.downloads), "arrow.down.circle")
                    Divider()
                    stat(AppCopy.text("market.stat.likes"), MarketItem.count(item.likes), "heart")
                    Divider()
                    stat(AppCopy.text("market.stat.released"), item.formattedDate ?? "—", "calendar")
                    Divider()
                    stat(AppCopy.text("market.stat.category"), MarketCategory.title(item.category), MarketCategory.symbol(item.category, fallback: "tag"))
                }
                .frame(height: 44)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: 680, alignment: .leading)

                if !related.isEmpty {
                    Divider()
                    Text(AppCopy.text("market.related")).font(.system(size: 16, weight: .medium))

                    LazyVGrid(columns: MarketRowLayout.columns, alignment: .leading, spacing: 20) {
                        ForEach(related) { other in
                            MarketRow(item: other, open: { openRelated(other) }) { EmptyView() }
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(item.id)
    }

    private func stat(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            MarketStat(symbol: symbol, text: label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
