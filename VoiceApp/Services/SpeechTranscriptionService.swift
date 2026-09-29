import Speech
import OSLog

private let logger = Logger(subsystem: "com.williamt.voiceapp", category: "Speech")

enum TechnicalVocabulary {
    // QA and testing vocabulary
    static let qaAndTesting = [
        "quality assurance", "QA", "SDET", "test plan", "test case", "test suite",
        "test scenario", "test data", "test environment", "acceptance criteria",
        "regression testing", "smoke testing", "sanity testing", "exploratory testing",
        "unit testing", "integration testing", "end-to-end testing", "system testing",
        "UAT", "API testing", "contract testing", "functional testing",
        "non-functional testing", "performance testing", "load testing", "stress testing",
        "soak testing", "accessibility testing", "security testing", "compatibility testing",
        "cross-browser testing", "defect", "bug", "bug triage", "flaky test",
        "severity", "priority", "root cause", "escalation", "stakeholder", "sign-off",
        "assertion", "matcher", "fixture", "mock", "stub", "spy", "test harness", "locator",
        "selector", "CSS selector", "XPath", "page object model", "headless browser",
        "DOM", "BDD", "Gherkin", "Given When Then", "Arrange Act Assert"
    ]

    // QA and developer tools
    static let qaAndDeveloperTools = [
        "Playwright", "Selenium", "Cypress", "Appium", "Postman", "Newman", "Swagger", "Jest",
        "Vitest", "pytest", "JUnit", "Cucumber", "Allure", "BrowserStack",
        "Sauce Labs",
        "Git", "GitHub", "GitLab", "Bitbucket", "pull request", "merge request", "commit",
        "branch", "rebase", "cherry-pick", "CI/CD", "GitHub Actions", "Jenkins", "CircleCI",
        "Buildkite", "Docker", "Kubernetes", "Helm", "Terraform", "Ansible", "Bash", "Zsh",
        "PowerShell", "SSH", "tmux", "Terminal", "iTerm2", "VS Code", "sprint", "backlog",
        "standup", "retro", "ticket", "release candidate", "staging", "production",
        "rollback", "hotfix", "deployment pipeline"
    ]

    // Cloud, databases, and security
    static let cloudAndSecurity = [
        "AWS", "Amazon Web Services", "Azure", "Google Cloud", "GCP", "Lambda", "EC2", "S3",
        "DynamoDB", "CloudFormation", "IAM", "VPC", "EKS", "ECS", "Cloudflare", "Vercel",
        "Netlify", "Nginx", "PostgreSQL", "MySQL", "MongoDB", "Redis", "Elasticsearch",
        "Kafka", "RabbitMQ", "Prometheus", "Grafana", "Datadog", "Sentry", "OAuth",
        "OAuth 2.0", "OpenID Connect", "OIDC", "JWT", "SAML", "SSO", "MFA", "Zero Trust",
        "TLS", "SSL", "secrets manager", "container", "microservice", "webhook", "latency",
        "throughput", "uptime", "SLA"
    ]

    // AI companies, models, and tools
    static let aiModelsAndTools = [
        "OpenAI", "ChatGPT", "GPT", "GPT-5", "GPT-5.1", "Codex", "GPT-5.1-Codex", "Whisper",
        "Anthropic", "Claude", "Claude Code", "Claude Opus", "Claude Sonnet", "Claude Haiku",
        "Google DeepMind", "Gemini", "Gemini Pro", "Gemini Flash", "Gemma", "Vertex AI",
        "Meta AI", "Llama", "Llama 4 Scout", "Llama 4 Maverick", "Mistral AI",
        "Mistral Large", "Mistral Medium", "Mistral Small", "Codestral", "Devstral",
        "Magistral", "Voxtral", "xAI", "Grok", "DeepSeek", "DeepSeek-R1", "DeepSeek-V3",
        "Qwen", "Cohere", "Command", "AI21", "Jamba", "NVIDIA", "NeMo", "Nemotron", "Parakeet",
        "Hugging Face", "Transformers", "vLLM", "Ollama", "LM Studio", "MCP",
        "Model Context Protocol", "RAG", "embeddings", "vector database",
        "function calling", "tool use", "agents", "agentic"
    ]

    // All terms combined for speech recognition hints
    static let terms: [String] = qaAndTesting + qaAndDeveloperTools + cloudAndSecurity + aiModelsAndTools
}

// Temporary diagnostics for the pause-boundary bug. Text is intentionally visible
// in local Debug logs; Release builds neither evaluate nor emit these messages.
private func speechDiagnostic(_ message: @autoclosure () -> String) {
    #if DEBUG
    let rendered = message()
    logger.notice("\(rendered, privacy: .public)")
    #endif
}

@MainActor
protocol SpeechTranscribing: AnyObject {
    func requestAuthorization() async -> Bool
    func transcribe(fileAt url: URL, duration: TimeInterval) async throws -> TranscriptionResult
}

@MainActor
final class AppleSpeechTranscriptionService: SpeechTranscribing {
    private var activeCollector: SpeechRecognitionCollector?

    func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            // TCC delivers this callback off the main thread. Resuming the
            // main-actor continuation from that callback traps and quits the app.
            return await Self.requestSpeechAuthorization()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(fileAt url: URL, duration: TimeInterval) async throws -> TranscriptionResult {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw RecordingError.transcriptionFailed
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = TechnicalVocabulary.terms

        let traceID = UUID().uuidString
        let traceStart = Date()
        speechDiagnostic("SpeechTrace \(traceID) START audioDuration=\(duration)")

        let collector = SpeechRecognitionCollector(traceID: traceID, traceStart: traceStart)
        activeCollector = collector
        do {
            let box: UncheckedSendableBox<CollectedTranscription> = try await withCheckedThrowingContinuation { continuation in
                collector.continuation = continuation
                collector.task = recognizer.recognitionTask(with: request, delegate: collector)
            }
            activeCollector = nil

            let collected = box.value
            let text = collected.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecordingError.noSpeechDetected
            }
            return TranscriptionResult(rawText: text, segments: collected.segments, duration: duration)
        } catch {
            activeCollector = nil
            if let error = error as? RecordingError { throw error }
            throw RecordingError.transcriptionFailed
        }
    }
}

private struct CollectedTranscription: @unchecked Sendable {
    let text: String
    let segments: [TranscriptionSegment]
}

private final class SpeechRecognitionCollector: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
    private let traceID: String
    private let traceStart: Date
    private var assembler = SpeechTranscriptAssembler()
    private var completed = false

    var continuation: CheckedContinuation<UncheckedSendableBox<CollectedTranscription>, Error>?
    var task: SFSpeechRecognitionTask?

    init(traceID: String, traceStart: Date) {
        self.traceID = traceID
        self.traceStart = traceStart
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription) {
        let segments = transcription.segments.map {
            SpeechTranscriptSegment(text: $0.substring, timestamp: $0.timestamp, duration: $0.duration)
        }
        speechDiagnostic("SpeechTrace \(traceID) HYPOTHESIS elapsed=\(Date().timeIntervalSince(traceStart)) count=\(segments.count) text=\(transcription.formattedString.debugDescription)")
        for (index, segment) in segments.enumerated() {
            speechDiagnostic("SpeechTrace \(traceID) HYPOTHESIS_SEGMENT index=\(index) start=\(segment.timestamp) duration=\(segment.duration) text=\(segment.text.debugDescription)")
        }
        assembler.add(segments, isFinal: false)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition recognitionResult: SFSpeechRecognitionResult) {
        let segments = recognitionResult.bestTranscription.segments.map {
            SpeechTranscriptSegment(text: $0.substring, timestamp: $0.timestamp, duration: $0.duration)
        }
        speechDiagnostic("SpeechTrace \(traceID) FINAL elapsed=\(Date().timeIntervalSince(traceStart)) count=\(segments.count) text=\(recognitionResult.bestTranscription.formattedString.debugDescription)")
        for (index, segment) in segments.enumerated() {
            speechDiagnostic("SpeechTrace \(traceID) FINAL_SEGMENT index=\(index) start=\(segment.timestamp) duration=\(segment.duration) text=\(segment.text.debugDescription)")
        }
        assembler.add(segments, isFinal: true)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        speechDiagnostic("SpeechTrace \(traceID) COMPLETE elapsed=\(Date().timeIntervalSince(traceStart)) success=\(successfully) segments=\(assembler.segments.count)")
        if successfully {
            succeed()
        } else {
            fail(task.error ?? RecordingError.transcriptionFailed)
        }
    }

    private func succeed() {
        guard !completed else { return }
        completed = true
        let segments = assembler.segments.sorted { $0.timestamp < $1.timestamp }
        let text = assembler.text
        speechDiagnostic("SpeechTrace \(traceID) OUTPUT text=\(text.debugDescription)")
        let result = CollectedTranscription(
            text: text,
            segments: segments.map { TranscriptionSegment(text: $0.text, timestamp: $0.timestamp) }
        )
        continuation?.resume(returning: UncheckedSendableBox(value: result))
        continuation = nil
    }

    private func fail(_ error: Error) {
        guard !completed else { return }
        completed = true
        let detail = error as NSError
        speechDiagnostic("SpeechTrace \(traceID) ERROR domain=\(detail.domain) code=\(detail.code) message=\(detail.localizedDescription.debugDescription)")
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

struct SpeechTranscriptSegment: Equatable {
    let text: String
    let timestamp: TimeInterval
    let duration: TimeInterval

    var end: TimeInterval { timestamp + duration }
}

struct SpeechTranscriptAssembler {
    private(set) var finalizedSegments: [SpeechTranscriptSegment] = []
    private var latestPartialSegments: [SpeechTranscriptSegment] = []

    mutating func add(_ segments: [SpeechTranscriptSegment], isFinal: Bool) {
        guard !segments.isEmpty else { return }
        if isFinal {
            mergeFinalSegments(segments)
            latestPartialSegments.removeAll(keepingCapacity: true)
        } else if finalizedSegments.isEmpty {
            latestPartialSegments = segments
        }
    }

    var segments: [SpeechTranscriptSegment] {
        finalizedSegments.isEmpty ? latestPartialSegments : finalizedSegments
    }

    var text: String {
        segments
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.text)
            .joined(separator: " ")
    }

    private mutating func mergeFinalSegments(_ incoming: [SpeechTranscriptSegment]) {
        let incomingStart = incoming.map(\.timestamp).min() ?? 0
        let incomingEnd = incoming.map(\.end).max() ?? incomingStart
        finalizedSegments.removeAll { existing in
            let overlaps = min(existing.end, incomingEnd) > max(existing.timestamp, incomingStart)
            let sameStart = abs(existing.timestamp - incomingStart) < 0.05
            return overlaps || sameStart
        }
        finalizedSegments.append(contentsOf: incoming)
    }
}

/// Carries a non-Sendable value across an actor boundary. The recognition
/// delegate resumes the continuation once, after its serial callbacks finish.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
