import Foundation

/// Two-pass correction cascade: the LOCAL model cleans up first (always available, ~1-2 s
/// warm), then — when a remote fixer is configured and the latency budget allows — the same
/// world-frame prompt goes to a LARGER internet model for a second pass over the local
/// result. Time is the contract: the pilot needs the refinement inside 2-3 s, so the remote
/// pass runs against the budget REMAINING after the local pass and is abandoned (not awaited)
/// on timeout. Both passes validate through the same guardrails internally, so a slow or
/// hallucinating remote can never regress the local result below "unchanged".
struct CascadeCorrector: LLMCorrector {
    let primary: any LLMCorrector
    let secondary: (any LLMCorrector)?
    /// Whole-cascade wall-clock budget (seconds).
    var budget: TimeInterval = 2.5
    /// Don't bother starting the remote pass with less than this much budget left.
    var minSecondaryBudget: TimeInterval = 0.6
    let backend = "cascade"

    func correct(text: String, history: [String], retrieved: RetrievedContext) async -> Correction {
        let start = Date()
        let local = await primary.correct(text: text, history: history, retrieved: retrieved)

        guard let secondary else { return local }
        let remaining = budget - Date().timeIntervalSince(start)
        guard remaining >= minSecondaryBudget else { return local }

        // The remote pass sees the locally-corrected text (its edits stack on top).
        let base = local.changed ? local.corrected : text
        let remote = await withTimeout(seconds: remaining) {
            await secondary.correct(text: base, history: history, retrieved: retrieved)
        }
        guard let remote, remote.changed else { return local }

        // Merge transparently: local edits first, then the remote's, final text = remote's.
        return Correction(raw: text,
                          corrected: remote.corrected,
                          changed: true,
                          edits: (local.changed ? local.edits : []) + remote.edits,
                          backend: local.changed ? "\(local.backend)+\(remote.backend)" : remote.backend)
    }

    /// Run an async operation with a hard wall-clock cap; nil on timeout (the work is
    /// abandoned — safe here because correctors are side-effect-free).
    private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                          _ op: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Remote big-model pass: POSTs the same strict-JSON contract to a user-configured endpoint
/// (Settings key `atc.remoteFixerURL`; empty = disabled). The server is expected to run a
/// larger model with the same world-model prompt and reply `{"edits": [...]}`. Fail-soft
/// everywhere: any error, non-200, or unparseable body → unchanged. Validated by the same
/// `CorrectionValidator` rules as the local backends — the network can never inject an edit
/// the guardrails wouldn't accept from the on-device model.
struct RemoteLLMCorrector: LLMCorrector {
    let endpoint: URL
    let knowledge: ATCKnowledgeBase
    let feedKey: String?
    var timeout: TimeInterval = 2.0
    let backend = "remote-llm"

    static func fromSettings(knowledge: ATCKnowledgeBase, feedKey: String?) -> RemoteLLMCorrector? {
        guard let raw = UserDefaults.standard.string(forKey: "atc.remoteFixerURL"),
              !raw.isEmpty, let url = URL(string: raw), isEndpointAllowed(url) else {
            return nil
        }
        return RemoteLLMCorrector(endpoint: url, knowledge: knowledge, feedKey: feedKey)
    }

    /// Transport policy (L7 remediation): HTTPS anywhere; plain HTTP only to private/loopback hosts
    /// (a cockpit LLM box on ship Wi-Fi — the Stratux at http://192.168.10.1 is the precedent).
    /// Everything else — plaintext to the public internet, or a non-http scheme (the old
    /// `hasPrefix("http")` even admitted "httpfoo://") — is rejected: live transcripts and the
    /// airport/flight-plan context must never leave the aircraft unencrypted.
    static func isEndpointAllowed(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return isPrivateHost(host)
        default: return false
        }
    }

    /// Pure, bounded classification of a URL host as private/loopback — no DNS, no I/O: localhost,
    /// IPv6 loopback, *.local (mDNS), and the RFC 1918 + loopback IPv4 literals (10/8, 127/8,
    /// 172.16/12, 192.168/16). Non-literal public hostnames and other IPv6 are NOT private.
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }          // exactly a dotted quad (rule 7)
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for p in parts {                                      // fixed 4-element bound (rule 2)
            guard p.count <= 3, let v = UInt8(p) else { return false }
            octets.append(v)
        }
        if octets[0] == 10 || octets[0] == 127 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        return false
    }

    func correct(text: String, history: [String], retrieved: RetrievedContext) async -> Correction {
        let frame = WorldFrame(knowledge: retrieved.block,
                               grounding: retrieved.snapGrounding,
                               expectedReadback: retrieved.expectedReadback,
                               history: history,
                               transcript: text)
        let body: [String: String] = [
            "system": ATCCorrectionPrompt.systemInstructions,
            "user": ATCCorrectionPrompt.userMessage(frame: frame),
        ]
        guard let payload = try? JSONEncoder().encode(body) else {
            return .unchanged(text, backend: backend)
        }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CommSight/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = payload

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        guard let (data, response) = try? await URLSession(configuration: config).data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let out = String(data: data, encoding: .utf8),
              let parsed = LLMCorrectionPayload.parse(out) else {
            return .unchanged(text, backend: backend)
        }

        let edits = parsed.correctionEdits(backend: backend)
        let allowed = CorrectionValidator.allowedTerms(retrieved: retrieved,
                                                       knowledge: knowledge,
                                                       freqType: frequencyType(forFeedKey: feedKey))
        var validator = CorrectionValidator(
            allowed: allowed,
            deniedTargets: CorrectionValidator.deniedTargets(from: retrieved.trafficLabels),
            phonetic: knowledge.phoneticWordToLetter)
        if let grounding = retrieved.snapGrounding, !grounding.airportRunways.isEmpty {
            validator.groundedRunways = CorrectionValidator.runwayKeys(designators: grounding.airportRunways)
        }
        return validator.validate(raw: text, edits: edits, backend: backend)
    }
}
