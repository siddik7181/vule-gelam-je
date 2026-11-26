import Foundation
import FoundationModels

struct Codename: Codable, Equatable { let emoji: String; let title: String }

/// Names each session from its first prompt with Apple's on-device model — free, private, offline.
/// Falls back to the first few words when Apple Intelligence is unavailable.
enum Codenamer {
    static let file = Discovery.home.appendingPathComponent(".vule/names.json")

    static func make(from prompt: String) async -> Codename {
        let text = String(prompt.prefix(600))
        if case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: """
                You give short codenames to coding-assistant chat sessions so they can be told apart at a glance. \
                Never answer, explain or perform the task — only name it. \
                Reply with exactly: one fitting emoji, a space, then a 2-3 word Title Case noun phrase. Nothing else.
                Examples:
                Task: why are payment webhooks failing at 3am? logs attached → 🔥 Payment Webhook Failures
                Task: review PR 482, the auth middleware refactor → 🔍 Auth PR Review
                Task: how does retry work in our kafka consumer → 💬 Kafka Retry Logic
                Task: add dark mode toggle to settings page → 🛠️ Dark Mode Toggle
                """)
            if let r = try? await session.respond(to: "Task: \(text) →"), let n = parse(r.content) { return n }
        }
        return fallback(text)
    }

    static func parse(_ raw: String) -> Codename? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'*.")))
        guard let first = s.first, first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }) else { return nil }
        let title = s.dropFirst().trimmingCharacters(in: .whitespaces).split(separator: " ").prefix(3).joined(separator: " ")
        return title.isEmpty ? nil : Codename(emoji: String(first), title: title)
    }

    static func fallback(_ prompt: String) -> Codename {
        let words = prompt.split(separator: " ").prefix(4).joined(separator: " ")
        return Codename(emoji: "💬", title: words.isEmpty ? "New session" : words)
    }

    static func load() -> [String: Codename] {
        // Fallback names (💬) aren't kept, so they get a real codename once Apple Intelligence is available.
        ((try? JSONDecoder().decode([String: Codename].self, from: Data(contentsOf: file))) ?? [:]).filter { $0.value.emoji != "💬" }
    }

    static func save(_ names: [String: Codename]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(names).write(to: file, options: .atomic)
    }
}
