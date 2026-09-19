import SwiftUI

struct LoopsView: View {
    @EnvironmentObject private var loops: LoopScheduler
    @EnvironmentObject private var localization: MobileLocalization
    @State private var name = ""
    @State private var prompt = ""
    @State private var minutes = "60"

    var body: some View {
        Section(localization.text("mobile.loops.title")) {
            ForEach(loops.loops) { loop in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(loop.name)
                        Spacer()
                        if loops.running == loop.id { ProgressView() }
                        Toggle("", isOn: Binding(get: { loop.enabled }, set: { loops.setEnabled($0, for: loop) })).labelsHidden()
                    }
                    Text(localization.format("mobile.loops.every", loop.minutes) + (loop.lastRun.map { localization.format("mobile.loops.lastRun", $0.formatted(date: .omitted, time: .shortened)) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if !loop.lastResult.isEmpty {
                        Text(loop.lastResult).font(.caption).lineLimit(4).foregroundStyle(.secondary)
                    }
                    Button(localization.text("mobile.loops.runNow")) { Task { await loops.run(loop) } }.font(.caption)
                }
                .swipeActions { Button(localization.text("common.remove"), role: .destructive) { loops.remove(loop) } }
            }
            TextField(localization.text("tasks.field.name"), text: $name)
            TextField(localization.text("loop.instructionLabel"), text: $prompt, axis: .vertical).lineLimit(1...4)
            TextField(localization.text("loop.minutesLabel"), text: $minutes).keyboardType(.numberPad)
            Button(localization.text("mobile.loops.add")) {
                loops.add(name: name, prompt: prompt, minutes: Int(minutes) ?? 60)
                loops.scheduleBackgroundRefresh()
                name = ""; prompt = ""; minutes = "60"
            }
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(localization.text("mobile.loops.backgroundHint"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
