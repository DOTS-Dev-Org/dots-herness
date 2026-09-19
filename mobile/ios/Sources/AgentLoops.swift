import Foundation
import BackgroundTasks
import UserNotifications
/// A prompt the phone re-runs on an interval — the mobile shape of the desktop's
/// scheduled tasks.
///
/// Two clocks drive it. While the app is open a plain timer fires on time. In the
/// background iOS decides: `BGAppRefreshTask` is opportunistic, so a loop may run
/// late or not at all until the app is next opened. That limit is the platform's,
/// not this code's, and the UI says so rather than pretending otherwise.
struct AgentLoop: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var name: String
    var prompt: String
    var minutes: Int
    var enabled = true
    var lastRun: Date?
    var lastResult = ""

    var isDue: Bool {
        guard enabled else { return false }
        guard let lastRun else { return true }
        return Date().timeIntervalSince(lastRun) >= Double(minutes * 60)
    }
}

@MainActor
final class LoopScheduler: ObservableObject {
    @Published private(set) var loops: [AgentLoop] = []
    @Published private(set) var running: String?

    static let taskIdentifier = "com.dots.herness.loops"
    private static let storageKey = "herness.loops"
    private static let tickSeconds: UInt64 = 30

    /// Each run gets a fresh agent so a loop never interleaves with what the user
    /// is typing in the Agent tab.
    private let makeAgent: @MainActor () -> MobileAgent
    private var ticker: Task<Void, Never>?

    init(makeAgent: @escaping @MainActor () -> MobileAgent) {
        self.makeAgent = makeAgent
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let value = try? JSONDecoder().decode([AgentLoop].self, from: data) { loops = value }
    }

    func add(name: String, prompt: String, minutes: Int) {
        loops.append(AgentLoop(name: name.isEmpty ? "Loop" : name, prompt: prompt, minutes: max(minutes, 1)))
        save()
    }

    func remove(_ loop: AgentLoop) {
        loops.removeAll { $0.id == loop.id }
        save()
    }

    func setEnabled(_ enabled: Bool, for loop: AgentLoop) {
        guard let index = loops.firstIndex(where: { $0.id == loop.id }) else { return }
        loops[index].enabled = enabled
        save()
    }

    /// Foreground ticker: exact while the app is open.
    func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runDue()
                try? await Task.sleep(for: .seconds(Double(Self.tickSeconds)))
            }
        }
    }

    func stopTicking() { ticker?.cancel(); ticker = nil }

    func runDue() async {
        for loop in loops where loop.isDue { await run(loop) }
    }

    func run(_ loop: AgentLoop) async {
        guard running == nil else { return }
        running = loop.id
        defer { running = nil }
        let agent = makeAgent()
        let result = await agent.sendAndWait(loop.prompt)
        guard let index = loops.firstIndex(where: { $0.id == loop.id }) else { return }
        loops[index].lastRun = Date()
        loops[index].lastResult = result
        save()
        notify(name: loops[index].name, result: result)
    }

    // MARK: - Background scheduling

    func scheduleBackgroundRefresh() {
        guard let soonest = loops.filter(\.enabled).map(\.minutes).min() else { return }
        BackgroundRefresh.schedule(identifier: Self.taskIdentifier, after: Double(soonest * 60))
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(name: String, result: String) {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = String(result.prefix(300))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(loops) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

enum BackgroundRefresh {
    static func schedule(identifier: String, after seconds: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        try? BGTaskScheduler.shared.submit(request)
    }
}

extension MobileAgent {
    /// Runs one prompt to completion and returns the agent's final text. Used by
    /// loops, which have no UI to stream into.
    func sendAndWait(_ prompt: String) async -> String {
        send(prompt)
        while isRunning {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return transcript.last { $0.role == .assistant }?.text
            ?? transcript.last { $0.role == .error }?.text
            ?? "The loop produced no output."
    }
}
