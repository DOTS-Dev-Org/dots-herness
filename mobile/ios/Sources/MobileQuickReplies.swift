import Foundation

struct MobileQuickReply: Equatable, Identifiable {
    let text: String
    var id: String { text }
}

enum MobileQuickReplySuggestions {
    static func choices(
        in assistantText: String,
        continueReply: String,
        declineReply: String
    ) -> [MobileQuickReply] {
        let lines = assistantText.components(separatedBy: .newlines)
        guard let question = lines.reversed().first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.trimmingCharacters(in: .whitespacesAndNewlines),
        let last = question.last, ["?", "？", "؟"].contains(String(last)) else { return [] }

        let optionPattern = try? NSRegularExpression(pattern: #"^[[:space:]]*[0-9]+[.)][[:space:]]*(.+?)[[:space:]]*$"#)
        let options = lines.compactMap { line -> String? in
            guard let optionPattern else { return nil }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = optionPattern.firstMatch(in: line, range: range),
                  let textRange = Range(match.range(at: 1), in: line) else { return nil }
            return normalize(String(line[textRange]))
        }.filter { !$0.isEmpty }

        var uniqueOptions: [String] = []
        for option in options where !uniqueOptions.contains(where: { $0.localizedCaseInsensitiveCompare(option) == .orderedSame }) {
            uniqueOptions.append(String(option.prefix(200)))
            if uniqueOptions.count == 2 { break }
        }
        if !uniqueOptions.isEmpty {
            if uniqueOptions.count == 1, !declineReply.isEmpty { uniqueOptions.append(declineReply) }
            return uniqueOptions.map(MobileQuickReply.init(text:))
        }

        guard let affirmative = affirmativeReply(for: question, fallback: continueReply) else { return [] }
        return [affirmative, declineReply]
            .filter { !$0.isEmpty }
            .prefix(2)
            .map(MobileQuickReply.init(text:))
    }

    private static func affirmativeReply(for question: String, fallback: String) -> String? {
        let body = String(question.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        let turkishEndings = [
            ("uygulayayım mı", "uygula"), ("güncelleyeyim mi", "güncelle"),
            ("değiştireyim mi", "değiştir"), ("göndereyim mi", "gönder"),
            ("başlatayım mı", "başlat"), ("ekleyeyim mi", "ekle"),
            ("sileyim mi", "sil"), ("yapayım mı", "yap"), ("edeyim mi", "et"),
        ]
        for (ending, action) in turkishEndings {
            if body.range(of: ending, options: .caseInsensitive).map({ $0.upperBound == body.endIndex }) == true {
                return finish(String(body.dropLast(ending.count)) + action)
            }
        }

        let englishPrefixes = [
            "Would you like me to ", "Do you want me to ", "Should I ",
            "Shall I ", "Can I ", "May I ",
        ]
        guard let prefix = englishPrefixes.first(where: { question.range(of: $0, options: [.caseInsensitive, .anchored]) != nil }) else { return nil }
        let action = body.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return action.isEmpty ? fallback : finish(String(action))
    }

    private static func normalize(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func finish(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        let capitalized = value.prefix(1).uppercased() + value.dropFirst()
        return capitalized.hasSuffix(".") ? capitalized : capitalized + "."
    }
}
