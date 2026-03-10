import Foundation

/// Detects which LLM model an agent is using from terminal output.
/// Scans lazily: first 10KB of session output and on /model command patterns.
public final class ModelDetector {
    public private(set) var currentModel: String?
    private var bytesScanned: Int = 0
    private let maxInitialScan = 10_240

    public init() {}

    /// Scan output for model identifiers. Only scans actively during
    /// the first 10KB of output, or when force=true (e.g., /model detected).
    public func scan(_ text: String, force: Bool = false) {
        bytesScanned += text.utf8.count

        // After initial window, only scan when forced
        if !force && bytesScanned > maxInitialScan && currentModel != nil {
            return
        }

        if let model = detectModel(in: text) {
            currentModel = model
        }
    }

    /// Check if text contains a /model command (triggers forced re-scan).
    public static func containsModelCommand(_ text: String) -> Bool {
        text.range(of: #"/model\b"#, options: .regularExpression) != nil
    }

    /// Reset state (e.g., on session restart).
    public func reset() {
        currentModel = nil
        bytesScanned = 0
    }

    // MARK: - Private

    private func detectModel(in text: String) -> String? {
        for (regex, extract) in Self.patterns {
            if let range = text.range(of: regex, options: .regularExpression) {
                return extract(String(text[range]))
            }
        }
        return nil
    }

    /// (regex, extractor) pairs. Extractor pulls the model name from the matched substring.
    private static let patterns: [(String, (String) -> String?)] = [
        // "model: claude-opus-4-6" or "Model: claude-sonnet-4-6"
        (#"(?i)(?:model|Model):\s*claude-\S+"#, { match in
            extractAfterColon(match)
        }),
        // Short names: "model: opus", "model: sonnet", "model: haiku"
        (#"(?i)(?:model|Model):\s*(?:opus|sonnet|haiku)\b"#, { match in
            extractAfterColon(match)
        }),
        // OpenAI: "model: gpt-5.4"
        (#"(?i)(?:model|Model):\s*gpt-[\d.]+\S*"#, { match in
            extractAfterColon(match)
        }),
        // Gemini: "model: gemini-2.5-pro"
        (#"(?i)(?:model|Model):\s*gemini\S*"#, { match in
            extractAfterColon(match)
        }),
        // "using claude-opus-4-6" / "using gpt-5.4"
        (#"(?i)using\s+(?:claude-\S+|gpt-[\d.]+\S*|gemini\S*)"#, { match in
            let parts = match.split(separator: " ")
            return parts.count >= 2 ? String(parts[1]) : nil
        }),
    ]

    private static func extractAfterColon(_ match: String) -> String? {
        guard let colonIdx = match.firstIndex(of: ":") else { return nil }
        let after = match[match.index(after: colonIdx)...]
        let trimmed = after.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
