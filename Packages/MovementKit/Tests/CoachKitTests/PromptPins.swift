/// SHA-256 prefixes (16 hex digits) of every prompt template per locale, keyed `<version>/<locale>`.
/// Regenerate with COACHKIT_GOLDEN_DIR (see PromptPinTests) after bumping a PromptVersion.
enum PromptPins {
    static let shas: [String: String] = [
        "set-review.v1/en": "1e959935501d4956",
        "set-review.v1/zh-Hans": "c71d3779ef136efb",
        "debrief.v1/en": "6460869c41ff2ccf",
        "debrief.v1/zh-Hans": "928ff1ad604cadb2",
        "meal-photo.v1/en": "94a209263b1c4460",
        "meal-photo.v1/zh-Hans": "54a3b246b8ddc8b0",
        "chat.v1/en": "ba59310c93ff88c4",
        "chat.v1/zh-Hans": "7a906e8163a348af",
    ]
}
