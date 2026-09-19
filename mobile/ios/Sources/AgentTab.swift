import SwiftUI

/// The Agent tab runs either the desktop session (over the control plane) or the
/// agent that runs on this phone. It defaults to the phone whenever no desktop
/// is paired, so a closed laptop is not a dead end.
struct AgentTab: View {
    @EnvironmentObject private var agent: MobileAgent
    @Binding var prompt: String

    var body: some View {
        LocalAgentView()
    }
}

struct LocalAgentView: View {
    @EnvironmentObject private var agent: MobileAgent
    @EnvironmentObject private var localization: MobileLocalization
    @State private var prompt = ""
    @State private var questionAnswer = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List(agent.transcript) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(for: turn)).font(.caption.bold()).foregroundStyle(color(for: turn))
                            Text(turn.text)
                                .font(turn.role == .tool ? .system(.footnote, design: .monospaced) : .body)
                                .lineLimit(turn.role == .tool ? 12 : nil)
                                .textSelection(.enabled)
                        }
                        .id(turn.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: agent.transcript.count) { _, _ in
                        if let last = agent.transcript.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                Divider()
                if let approval = agent.approvalRequest {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localization.text("mobile.agent.approvalRequired")).font(.headline)
                        Text(localization.format("mobile.agent.allowTool", approval.toolName))
                        HStack {
                            Button(localization.text("permission.allowOnce")) { agent.answerApproval(approval.id, accepted: true) }
                            Button(localization.text("permission.reject"), role: .destructive) { agent.answerApproval(approval.id, accepted: false) }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                if let question = agent.questionRequest {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localization.text("mobile.agent.clarification")).font(.headline)
                        Text(question.question).font(.subheadline)
                        TextField(localization.text("mobile.agent.answer"), text: $questionAnswer)
                        Button(localization.text("mobile.agent.answer")) {
                            let answer = questionAnswer
                            questionAnswer = ""
                            agent.answerQuestion(question.id, answers: [answer])
                        }
                        .disabled(questionAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                DisclosureGroup(localization.text("mobile.agent.eventHistory")) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(agent.events.suffix(30))) { event in
                                Text("\(event.kind) \(event.payload["preview"] ?? event.payload["text"] ?? "")")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                HStack {
                    TextField(localization.text("mobile.agent.ask") + "…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    if agent.isRunning {
                        Button(localization.text("mobile.agent.queue")) { agent.send(prompt, mode: "queue", planMode: agent.planMode); prompt = "" }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(localization.text("conversation.steer")) { agent.send(prompt, mode: "steer", planMode: agent.planMode); prompt = "" }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(localization.text("common.stop"), role: .destructive) { agent.cancel() }
                    } else {
                        Button(localization.text("mobile.agent.send")) { agent.send(prompt, planMode: agent.planMode); prompt = "" }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
            }
            .navigationTitle(localization.text("mobile.agent.phone"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(localization.text("mobile.agent.model"), selection: Binding(get: { agent.model }, set: { agent.setModel($0) })) {
                            ForEach(MobileAgent.models, id: \.self) { Text($0).tag($0) }
                        }
                        Toggle(localization.text("mobile.agent.plan"), isOn: $agent.planMode)
                        Button(localization.text("mobile.agent.newConversation"), role: .destructive) { agent.reset() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    private func label(for turn: AgentTurn) -> String {
        switch turn.role {
        case .user: return localization.text("mobile.agent.user")
        case .assistant: return localization.text("conversation.assistant")
        case .tool: return turn.toolName ?? "tool"
        case .error: return localization.text("mobile.agent.error")
        case .system: return localization.text("mobile.event.runSummary")
        }
    }

    private func color(for turn: AgentTurn) -> Color {
        switch turn.role {
        case .user: return .secondary
        case .assistant: return .accentColor
        case .tool: return .orange
        case .error: return .red
        case .system: return .secondary
        }
    }
}
