public enum IndexEvaluation: Sendable {
    case index(partition: String)
    case deferred(reason: String)
    case skip(reason: String)
}
