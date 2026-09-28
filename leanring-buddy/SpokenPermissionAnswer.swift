//
//  SpokenPermissionAnswer.swift
//  leanring-buddy
//
//  Turns what the user said after "want me to edit NOTES.md?" into allow or
//  deny (chunk 6 of .claude/plans/active/agent-sidecar/plan.md). Deliberately
//  cautious: it is a yes only when the answer opens with a clear yes and has
//  no negation anywhere ("yes, but wait" is a no). Everything else is a no,
//  and the caller passes the user's words to Claude as the denial reason, so
//  "no, edit the other file" still reaches it.
//

import Foundation

enum SpokenPermissionAnswer {
    private static let affirmativeOpenings: [[String]] = [
        ["yes"], ["yeah"], ["yep"], ["yup"], ["sure"], ["ok"], ["okay"], ["allow"],
        ["absolutely"], ["definitely"], ["affirmative"], ["please"],
        ["do", "it"], ["go", "ahead"], ["go", "for", "it"], ["sounds", "good"], ["of", "course"]
    ]

    private static let negationWords: Set<String> = [
        "no", "nope", "nah", "not", "don't", "dont", "stop", "wait", "cancel",
        "deny", "never", "hold", "later", "instead", "but"
    ]

    /// True only for a clear yes.
    static func isAffirmative(_ spokenAnswer: String) -> Bool {
        let answerWords = words(in: spokenAnswer)
        guard !answerWords.isEmpty else { return false }

        let containsNegation = answerWords.contains { negationWords.contains($0) }
            || zip(answerWords, answerWords.dropFirst()).contains { "\($0) \($1)" == "do not" }
        guard !containsNegation else { return false }

        return affirmativeOpenings.contains { openingWords in
            answerWords.count >= openingWords.count && Array(answerWords.prefix(openingWords.count)) == openingWords
        }
    }

    /// Lowercased words with punctuation stripped; apostrophes kept so "don't" survives.
    private static func words(in spokenAnswer: String) -> [String] {
        spokenAnswer
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }
}
