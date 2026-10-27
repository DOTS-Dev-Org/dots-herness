// Copyright (c) 2026 DOTS
// Bots: named assistants with their own instructions, model and running chat.

import Foundation
import PluginRuntime

public struct BotMessage: Identifiable, Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: String
    public var role: Role
    public var text: String
    public var date: Date
    /// False for a user message the bot has not been handed yet.
    public var delivered: Bool

    public init(
        id: String = UUID().uuidString, role: Role, text: String, date: Date = Date(), delivered: Bool = true
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.delivered = delivered
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        date = try values.decode(Date.self, forKey: .date)
        // Chats saved before delivery was tracked were all answered.
        delivered = try values.decodeIfPresent(Bool.self, forKey: .delivered) ?? true
    }
}

public struct Bot: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var symbol: String
    /// Optional local image displayed instead of the bot's SF Symbol.
    public var imagePath: String?
    public var instructions: String
    /// Empty follows the app's selected model.
    public var modelID: String
    /// Empty leaves the level to the app; one the model rejects is ignored.
    public var effort: String
    /// When set, the bot works as an agent with tools inside this folder.
    public var workspacePath: String
    public var messages: [BotMessage]
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        symbol: String = "sparkles",
        imagePath: String? = nil,
        instructions: String = "",
        modelID: String = "",
        effort: String = "",
        workspacePath: String = "",
        messages: [BotMessage] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.imagePath = imagePath
        self.instructions = instructions
        self.modelID = modelID
        self.effort = effort
        self.workspacePath = workspacePath
        self.messages = messages
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        symbol = try values.decode(String.self, forKey: .symbol)
        imagePath = try values.decodeIfPresent(String.self, forKey: .imagePath)
        instructions = try values.decode(String.self, forKey: .instructions)
        modelID = try values.decode(String.self, forKey: .modelID)
        // Bots saved before effort could be picked follow the app.
        effort = try values.decodeIfPresent(String.self, forKey: .effort) ?? ""
        workspacePath = try values.decode(String.self, forKey: .workspacePath)
        messages = try values.decode([BotMessage].self, forKey: .messages)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public static let symbols = [
        "sparkles", "magnifyingglass", "chevron.left.forwardslash.chevron.right", "pencil.line",
        "chart.bar", "globe", "book", "lightbulb", "briefcase", "heart",
    ]

    /// Starting points offered on the empty Bots screen.
    public static var presets: [Bot] {
        [
            Bot(name: AppCopy.text("bots.preset.assistant"), symbol: "sparkles",
                instructions: "You are a capable personal assistant. Be direct, ask when a request is ambiguous, and keep track of what the user told you earlier in this chat."),
            Bot(name: AppCopy.text("bots.preset.researcher"), symbol: "magnifyingglass",
                instructions: "You are a careful researcher. Separate what is established from what is uncertain, name your sources when you have them, and say plainly when you do not know."),
            Bot(name: AppCopy.text("bots.preset.coder"), symbol: "chevron.left.forwardslash.chevron.right",
                instructions: "You are a senior software engineer. Prefer the smallest change that solves the problem, explain trade-offs briefly, and show code rather than describing it."),
        ]
    }
}

private struct BotTransferArchive: Codable {
    static let identifier = "dots-herness-bots"
    static let currentVersion = 1

    let formatIdentifier: String
    let version: Int
    let bots: [Bot]
}

@MainActor
public final class BotStore: ObservableObject {
    @Published public private(set) var bots: [Bot] = []
    @Published public var selectedBotID: String?
    @Published public private(set) var busyBotIDs: Set<String> = []
    /// The reply being written, per bot, until it is committed as a message.
    @Published public private(set) var streaming: [String: String] = [:]
    @Published public private(set) var errors: [String: String] = [:]

    /// Turns of history sent with each message; older ones stay on screen only.
    static let historyLimit = 40

    private let root: URL
    private let router: RouterController
    private let paths: SupportPaths
    private let systemPrompt: () -> String
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Messages of the running agent turn already posted to the chat, per bot.
    private var relayed: [String: Set<String>] = [:]
    /// The reply in progress per bot; a restarted reply gets a new one, so its predecessor goes quiet.
    private var runs: [String: UUID] = [:]
    /// Bots whose current reply has streamed text.
    private var streamed: Set<String> = []
    /// The agent at work for a bot, so a message sent meanwhile can steer it.
    private var hosts: [String: AgentBridge] = [:]
    private var hasLoaded = false

    public init(root: URL, router: RouterController, paths: SupportPaths, systemPrompt: @escaping () -> String) {
        self.root = root
        self.router = router
        self.paths = paths
        self.systemPrompt = systemPrompt
    }

    public func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        bots = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Bot.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
        if selectedBotID == nil { selectedBotID = bots.first?.id }
    }

    public func bot(_ id: String?) -> Bot? {
        guard let id else { return nil }
        return bots.first { $0.id == id }
    }

    public func isBusy(_ id: String) -> Bool { busyBotIDs.contains(id) }

    /// Adds or replaces a bot. List order is creation order, so editing never reshuffles it.
    public func upsert(_ bot: Bot) {
        var bot = bot
        bot.updatedAt = Date()
        let previousImagePath = self.bot(bot.id)?.imagePath
        if let index = bots.firstIndex(where: { $0.id == bot.id }) {
            bots[index] = bot
        } else {
            bots.insert(bot, at: 0)
        }
        if write(bot), previousImagePath != bot.imagePath {
            removeManagedAvatar(at: previousImagePath)
        }
    }

    public func exportArchive() throws -> Data {
        loadIfNeeded()
        let archive = BotTransferArchive(
            formatIdentifier: BotTransferArchive.identifier,
            version: BotTransferArchive.currentVersion,
            bots: bots
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    /// Imports a full bot archive as new bots, keeping histories and workspace paths.
    public func importArchive(_ data: Data) throws -> [String] {
        loadIfNeeded()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(BotTransferArchive.self, from: data)
        guard archive.formatIdentifier == BotTransferArchive.identifier,
              archive.version == BotTransferArchive.currentVersion,
              !archive.bots.isEmpty else {
            throw Self.invalidArchive("Unsupported or empty bot archive.")
        }

        var imported: [Bot] = []
        for source in archive.bots {
            guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Self.invalidArchive("A bot in the archive has no name.")
            }
            var bot = source
            bot.id = UUID().uuidString
            bot.messages = source.messages.map { message in
                BotMessage(
                    id: UUID().uuidString,
                    role: message.role,
                    text: message.text,
                    date: message.date,
                    delivered: message.delivered
                )
            }
            imported.append(bot)
        }

        for bot in imported.reversed() { upsert(bot) }
        selectedBotID = imported.first?.id
        return imported.map(\.id)
    }

    private static func invalidArchive(_ reason: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: reason))
    }

    public func delete(_ id: String) {
        stop(id)
        let fileManager = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let records = files.filter { file in
            guard file.pathExtension.lowercased() == "json" else { return false }
            if file.deletingPathExtension().lastPathComponent == id { return true }
            guard let data = try? Data(contentsOf: file), let stored = try? decoder.decode(Bot.self, from: data)
            else { return false }
            return stored.id == id
        }
        do {
            for file in records { try fileManager.removeItem(at: file) }
        } catch {
            errors[id] = error.localizedDescription
            return
        }
        removeManagedAvatar(at: bot(id)?.imagePath)
        bots.removeAll { $0.id == id }
        if selectedBotID == id { selectedBotID = bots.first?.id }
    }

    public func clearHistory(_ id: String) {
        guard var bot = bot(id) else { return }
        stop(id)
        bot.messages = []
        upsert(bot)
    }

    public func stop(_ id: String) {
        tasks[id]?.cancel()
    }

    /// Sends a message. While the bot is busy the message joins the work in progress:
    /// an agent is steered with it, a reply that has not said anything yet starts over
    /// with it included, and otherwise it waits and is answered with the others that waited.
    public func send(_ text: String, to id: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var bot = bot(id) else { return }
        let unanswered = bot.messages.last?.role == .user
        bot.messages.append(BotMessage(role: .user, text: text, delivered: false))
        upsert(bot)
        errors[id] = nil
        guard isBusy(id) else { return start(id) }
        if let host = hosts[id], host.isBusy {
            // Steering restarts the agent's current step with everything it has done plus
            // this message. It counts as delivered once the agent's own chat shows it.
            Task { await host.send(text: text, mode: .steer) }
        } else if unanswered {
            start(id)
        }
    }

    private func hasUndelivered(_ id: String) -> Bool {
        bot(id)?.messages.contains { !$0.delivered } ?? false
    }

    private func markDelivered(in id: String, where matches: (BotMessage) -> Bool = { _ in true }) {
        guard var bot = bot(id) else { return }
        let pending = bot.messages.indices.filter { !bot.messages[$0].delivered && matches(bot.messages[$0]) }
        guard !pending.isEmpty else { return }
        for index in pending { bot.messages[index].delivered = true }
        upsert(bot)
    }

    /// Starts a reply to the chat as it stands, replacing one in progress.
    private func start(_ id: String) {
        tasks[id]?.cancel()
        // The request built below carries every message in the chat.
        markDelivered(in: id)
        guard let bot = bot(id) else { return }
        let run = UUID()
        runs[id] = run
        busyBotIDs.insert(id)
        streaming[id] = ""
        streamed.remove(id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            var finished = false
            do {
                try await self.reply(for: bot, run: run)
                finished = true
            } catch is CancellationError {
                if self.runs[id] == run { self.post(self.streaming[id] ?? "", to: id) }
            } catch {
                if self.runs[id] == run {
                    self.errors[id] = (error as? NativeAgentError)?.message ?? error.localizedDescription
                }
            }
            guard self.runs[id] == run else { return }
            // Messages that waited are answered together, as one turn. After a stop or an
            // error they stay undelivered until the user sends again.
            if finished, self.hasUndelivered(id) { return self.start(id) }
            self.streaming[id] = nil
            self.busyBotIDs.remove(id)
            self.tasks[id] = nil
            self.runs[id] = nil
        }
    }

    /// Adds a reply to the chat, as one message per part the bot separated.
    private func post(_ text: String, to id: String) {
        let parts = Self.splitMessages(text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty, var current = bot(id) else { return }
        current.messages += parts.map { BotMessage(role: .assistant, text: $0) }
        upsert(current)
    }

    /// Cuts a reply at lines holding only `---`, outside code fences. Parts are raw:
    /// each keeps its line breaks and may be empty.
    static func splitMessages(_ text: String) -> [String] {
        var parts = [""]
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if !inFence, trimmed == "---" {
                parts.append("")
            } else {
                parts[parts.count - 1] += line + "\n"
            }
        }
        return parts
    }

    /// Consecutive messages from one side as a single turn, joined the way the bot
    /// is told to separate them.
    static func turns(_ messages: some Sequence<BotMessage>) -> [BotMessage] {
        messages.reduce(into: []) { turns, message in
            if turns.last?.role == message.role {
                turns[turns.count - 1].text += "\n---\n" + message.text
            } else {
                turns.append(message)
            }
        }
    }

    private func reply(for bot: Bot, run: UUID) async throws {
        let model = router.usableModelID(bot.modelID)
        if let workspace = ScheduledTaskRunner.validWorkspace(bot.workspacePath) {
            return try await agentReply(for: bot, workspace: workspace, model: model.isEmpty ? nil : model)
        }
        var messages = [AgentMessage(role: .system, content: Self.persona(for: bot))]
        messages += Self.turns(bot.messages.suffix(Self.historyLimit)).map {
            AgentMessage(role: $0.role == .user ? .user : .assistant, content: $0.text)
        }
        let id = bot.id
        let response = try await router.complete(
            messages: messages,
            model: model.isEmpty ? nil : model,
            effort: bot.effort.isEmpty ? nil : bot.effort,
            onDelta: { [weak self] delta in
                guard case .text(let piece) = delta else { return }
                await self?.appendStreaming(piece, to: id, run: run)
            }
        )
        try Task.checkCancellation()
        // Streamed text was posted part by part; the full answer is only needed when nothing streamed.
        post(streamed.contains(id) ? streaming[id] ?? "" : response.message.content, to: id)
        streaming[id] = ""
    }

    /// Finished parts are posted as soon as their separator arrives; the rest keeps streaming.
    private func appendStreaming(_ piece: String, to id: String, run: UUID) {
        guard runs[id] == run else { return }
        streamed.insert(id)
        let pending = (streaming[id] ?? "") + piece
        // Only whole lines can be a separator: the last one may still be growing.
        guard let lineEnd = pending.lastIndex(of: "\n") else { return streaming[id] = pending }
        let parts = Self.splitMessages(String(pending[..<lineEnd]))
        guard parts.count > 1 else { return streaming[id] = pending }
        post(parts.dropLast().joined(separator: "---\n"), to: id)
        streaming[id] = parts[parts.count - 1] + pending[pending.index(after: lineEnd)...]
    }

    /// Posts what the agent has said so far in its run, each message once.
    private func relayReplies(from host: AgentBridge, conversationID: String, to id: String) {
        let messages = host.conversations.first { $0.id == conversationID }?.messages ?? []
        for message in messages where message.kind == .assistant && !message.streaming
            && relayed[id, default: []].insert(message.id).inserted {
            post(message.text, to: id)
        }
        // The first user message is the run's prompt; later ones are steers the agent accepted.
        let steers = Set(messages.filter { $0.kind == .user }.dropFirst().map(\.text))
        if !steers.isEmpty { markDelivered(in: id) { steers.contains($0.text) } }
    }

    /// One agent run in a transient host, the way scheduled tasks run: tools are
    /// confined to the bot's folder with no network, and the run's own chat is
    /// removed afterwards because the bot keeps the transcript.
    private func agentReply(for bot: Bot, workspace: String, model: String?) async throws {
        let host = AgentBridge(paths: paths, router: router, permissionMode: .full, nonInteractive: true)
        host.effortOverride = bot.effort.isEmpty ? nil : bot.effort
        host.updateSystemPrompt(systemPrompt() + "\n\n" + Self.persona(for: bot) + "\n\n" + Self.agentChatStyle)
        host.start(workspacePath: workspace)
        host.setSandboxPolicy(SandboxExecutionPolicy(
            workspaceURL: URL(fileURLWithPath: workspace, isDirectory: true),
            networkAccess: false
        ))
        await host.refreshConnection()
        guard host.isReady else { throw NativeAgentError(host.status) }
        host.newConversation()
        guard let conversationID = host.selectedID else { throw NativeAgentError(AppCopy.text("bots.error.noReply")) }
        defer { host.deleteConversation(conversationID) }

        // The user's latest messages are one turn; everything before it is context.
        var turns = Self.turns(bot.messages.suffix(Self.historyLimit))
        let latest = turns.popLast()?.text ?? ""
        let earlier = turns.map { "\($0.role == .user ? "User" : "You"): \($0.text)" }
        let prompt = earlier.isEmpty ? latest : """
        Earlier in this chat:
        \(earlier.joined(separator: "\n\n"))

        New message from the user:
        \(latest)
        """
        let id = bot.id
        relayed[id] = nil
        // ponytail: polls the run's chat; observe AgentBridge instead if 0.3 s feels laggy.
        let relay = Task { [weak self] in
            while !Task.isCancelled {
                self?.relayReplies(from: host, conversationID: conversationID, to: id)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { relay.cancel() }
        hosts[id] = host
        defer { if hosts[id] === host { hosts[id] = nil } }
        await host.send(text: prompt, mode: .queue, modelOverride: model)
        // A steered run restarts in a fresh task, which the call above does not wait for.
        while host.isBusy, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        if Task.isCancelled { host.stopCurrentRun() }
        relayReplies(from: host, conversationID: conversationID, to: id)
        try Task.checkCancellation()
        let last = host.conversations.first { $0.id == conversationID }?.messages.last
        let output = last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard last?.kind == .assistant, !output.isEmpty else {
            throw NativeAgentError(output.isEmpty ? AppCopy.text("bots.error.noReply") : output)
        }
    }

    static let chatStyle = """
    You talk with the user in a messaging app. Write the way a person texts: short, natural messages, \
    no headings and no preamble. When several messages read better than one (a quick acknowledgement, \
    then the answer, then a follow-up question), put a line holding only --- between them; each part \
    is delivered as its own message. Send a single message when one is enough.

    The user may also send several messages in a row; they reach you joined by --- lines. A later \
    one usually adds to or corrects the earlier request, so treat them as one request with the \
    addition folded in. Answer them separately only when they are clearly unrelated.
    """

    static let agentChatStyle = """
    Anything you write before using a tool is delivered to the user right away as its own message. \
    When asked to do something, first say briefly what you are about to do, send a short update when \
    a long task reaches a milestone, and finish with the result.

    A message that arrives while you are working usually adds to or corrects the task in progress: \
    keep the work you have done, fold the addition in and carry on. Treat it as a new task only when \
    it is clearly unrelated, and then finish the current task first unless the user tells you to stop.
    """

    static func persona(for bot: Bot) -> String {
        let instructions = bot.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return "You are \"\(bot.name)\", a bot the user set up in HerNess."
            + (instructions.isEmpty ? "" : "\n\n\(instructions)")
            + "\n\n" + chatStyle
    }

    private func fileURL(for id: String) -> URL {
        root.appendingPathComponent("\(id).json")
    }

    /// Keeps selected images in app-managed storage so moving the source file does not
    /// break the bot's avatar.
    public func copyAvatar(from source: URL) throws -> String {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent("avatars", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        let safeExtension = ext.range(of: #"^[a-z0-9]{1,8}$"#, options: .regularExpression) == nil ? "img" : ext
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(safeExtension)")
        let hasScopedAccess = source.startAccessingSecurityScopedResource()
        defer { if hasScopedAccess { source.stopAccessingSecurityScopedResource() } }
        try fileManager.copyItem(at: source, to: destination)
        return destination.path
    }

    private func removeManagedAvatar(at path: String?) {
        guard let path else { return }
        let directory = root.appendingPathComponent("avatars", isDirectory: true).standardizedFileURL.path + "/"
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.path.hasPrefix(directory) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    @discardableResult
    private func write(_ bot: Bot) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(bot) else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: bot.id), options: .atomic)
            return true
        } catch {
            errors[bot.id] = error.localizedDescription
            return false
        }
    }
}
