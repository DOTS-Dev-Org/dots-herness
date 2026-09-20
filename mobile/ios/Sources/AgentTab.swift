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
    @State private var draftAttachments: [MobileAttachment] = []
    @State private var showingFileImporter = false

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
                if !draftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(draftAttachments) { attachment in
                                HStack(spacing: 4) {
                                    Image(systemName: "paperclip")
                                    Text(attachment.displayName).lineLimit(1)
                                    Button { draftAttachments.removeAll { $0.id == attachment.id } } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.thinMaterial, in: Capsule())
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                HStack {
                    Button { showingFileImporter = true } label: { Image(systemName: "paperclip") }
                        .accessibilityLabel("Attach file")
                    TextField(localization.text("mobile.agent.ask") + "…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    if agent.isRunning {
                        Button(localization.text("mobile.agent.queue")) { send(mode: "queue") }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftAttachments.isEmpty)
                        Button(localization.text("conversation.steer")) { send(mode: "steer") }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftAttachments.isEmpty)
                        Button(localization.text("common.stop"), role: .destructive) { agent.cancel() }
                    } else {
                        Button(localization.text("mobile.agent.send")) { send(mode: "queue") }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftAttachments.isEmpty)
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
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                guard let urls = try? result.get() else { return }
                for url in urls {
                    guard let attachment = MobileAttachment(url: url), !draftAttachments.contains(where: { $0.sourceLocator == attachment.sourceLocator }) else { continue }
                    draftAttachments.append(attachment)
                }
            }
        }
    }

    private func send(mode: String) {
        agent.send(prompt, attachments: draftAttachments, mode: mode, planMode: agent.planMode)
        prompt = ""
        draftAttachments = []
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
