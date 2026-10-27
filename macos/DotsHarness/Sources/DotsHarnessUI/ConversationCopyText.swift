import Foundation
import DotsHarnessCore

enum ConversationCopyText {
    static func text(for message: ChatMessage, in messages: [ChatMessage]) -> String {
        guard message.kind == .assistant,
              let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else {
            return message.text
        }

        let previousUserIndex = messages[..<messageIndex].lastIndex(where: { $0.kind == .user })
        let startIndex = previousUserIndex.map { $0 + 1 } ?? messages.startIndex
        return messages[startIndex...messageIndex]
            .filter { $0.kind == .assistant }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}
