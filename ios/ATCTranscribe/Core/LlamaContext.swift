import Foundation

// MARK: - Engine factory (always present)

/// Build a llama.cpp CPU engine for `modelPath`, or nil when the package isn't linked / the
/// model can't load. Isolated here so the rest of the app is independent of the llama module.
func makeLlamaEngine(modelPath: String, nThreads: Int = 2) -> LLMEngine? {
    #if canImport(llama)
    return LlamaContext(modelPath: modelPath, nThreads: nThreads)
    #else
    return nil
    #endif
}

#if canImport(llama)
import llama

enum LlamaError: Error { case modelLoad, contextInit, tokenize, decode }

/// Thin CPU-only wrapper over the llama.cpp C API. The heavy token loop runs on a private
/// **utility-QoS** serial queue (never the cooperative pool or main thread) and yields the CPU
/// to higher-priority work, so background refinement can't slow WhisperKit. `n_gpu_layers = 0`
/// keeps it entirely on the CPU, leaving the ANE/GPU for transcription.
///
/// **Prompt-prefix reuse:** the context is persistent and remembers which tokens are resident in
/// its KV cache. Each call reuses the longest common token prefix with the previous prompt
/// (the static system + few-shot block is identical every transmission) and only evaluates the
/// changed suffix (RAG + transcript), instead of re-processing ~800 prompt tokens from scratch
/// every time. The serial queue means the context is only ever touched by one call at a time.
///
/// NOTE: targets the modern llama.cpp C API (vocab + sampler chain + `llama_memory_*`, llama.cpp
/// 2025). If the package pinned in project.yml exposes different symbol names, this one file is
/// where they're adjusted — every other file is plain Foundation and unaffected.
final class LlamaContext: LLMEngine, @unchecked Sendable {
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let nThreads: Int32
    private let nCtx: UInt32
    private let queue = DispatchQueue(label: "net.atctranscribe.llama", qos: .utility)
    /// Set ATC_LLM_PERF=1 to log llama.cpp's per-call prompt-eval vs gen timings to stderr.
    private let perfLog = ProcessInfo.processInfo.environment["ATC_LLM_PERF"] != nil

    // Persistent context + the tokens currently resident in its KV cache (accessed only on the
    // serial `queue`, so no extra locking). Enables prompt-prefix reuse across calls.
    private var ctx: OpaquePointer?
    private var cachedTokens: [llama_token] = []

    private static let backendLock = NSLock()
    private static var backendReady = false

    init?(modelPath: String, nThreads: Int = 2, nCtx: UInt32 = 2048) {
        LlamaContext.initBackendOnce()
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 0   // CPU only — leave the ANE/GPU for Whisper.
        guard let m = modelPath.withCString({ llama_model_load_from_file($0, mparams) }) else { return nil }
        guard let v = llama_model_get_vocab(m) else { llama_model_free(m); return nil }
        self.model = m
        self.vocab = v
        self.nThreads = Int32(nThreads)
        self.nCtx = nCtx
    }

    deinit {
        if let ctx { llama_free(ctx) }
        llama_model_free(model)
    }

    private static func initBackendOnce() {
        backendLock.lock(); defer { backendLock.unlock() }
        if !backendReady { llama_backend_init(); backendReady = true }
    }

    func generate(prompt: String, grammar: String?, maxTokens: Int, stop: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.generateSync(prompt: prompt, grammar: grammar,
                                                                  maxTokens: maxTokens, stop: stop)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: Core loop (private queue)

    private func generateSync(prompt: String, grammar: String?, maxTokens: Int, stop: [String]) throws -> String {
        let ctx = try ensureContext()
        if perfLog { llama_perf_context_reset(ctx) }

        let newTokens = try tokenize(prompt, addBOS: true)
        guard !newTokens.isEmpty else { throw LlamaError.tokenize }

        // Reuse the longest common token prefix already resident in the KV cache; only the
        // diverging suffix is (re-)evaluated. Keep at least one token to decode so we get logits.
        var reuse = commonPrefixLength(cachedTokens, newTokens)
        if reuse >= newTokens.count { reuse = newTokens.count - 1 }
        if reuse < 0 { reuse = 0 }

        // Drop everything past the reusable prefix from the KV cache (positions [reuse, ∞)).
        if reuse < cachedTokens.count {
            llama_memory_seq_rm(llama_get_memory(ctx), 0, llama_pos(reuse), -1)
        }

        // Evaluate only the new suffix; positions continue automatically from `reuse`.
        var suffix = Array(newTokens[reuse...])
        guard decode(ctx, &suffix) else { cachedTokens = []; throw LlamaError.decode }
        cachedTokens = newTokens

        // Greedy (temperature 0). Grammar is intentionally unused — its sampler can throw an
        // uncatchable C++ exception (see LocalLLMCorrector / the WARNING below).
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if let grammar {  // WARNING: opt-in only; a grammar-stack mismatch aborts the process.
            let g = grammar.withCString { gptr in "root".withCString { rptr in
                llama_sampler_init_grammar(vocab, gptr, rptr)
            } }
            if let g { llama_sampler_chain_add(sampler, g) }
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var output = ""
        for _ in 0..<maxTokens {
            let cur = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, cur) { break }
            llama_sampler_accept(sampler, cur)
            output += piece(cur)
            if let s = stop.first(where: { !$0.isEmpty && output.hasSuffix($0) }) {
                output.removeLast(s.count); break
            }
            var one = [cur]
            guard decode(ctx, &one) else { break }
            cachedTokens.append(cur)   // keep the cache record in sync with the KV contents
        }

        if perfLog {
            let p = llama_perf_context(ctx)
            let line = "[llm-perf] prompt_eval=\(Int(p.t_p_eval_ms))ms (\(p.n_p_eval) tok)  " +
                       "gen=\(Int(p.t_eval_ms))ms (\(p.n_eval) tok)  reused_prefix=\(reuse) tok\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        return output
    }

    /// Lazily create the persistent context (on the serial queue).
    private func ensureContext() throws -> OpaquePointer {
        if let ctx { return ctx }
        var cparams = llama_context_default_params()
        cparams.n_ctx = nCtx
        cparams.n_threads = nThreads
        cparams.n_threads_batch = nThreads
        cparams.no_perf = false   // populate the prompt-eval/gen ms used by the ATC_LLM_PERF log
        guard let c = llama_init_from_model(model, cparams) else { throw LlamaError.contextInit }
        ctx = c
        cachedTokens = []
        return c
    }

    /// Decode a batch of tokens (positions tracked automatically by llama_decode, seq 0).
    private func decode(_ ctx: OpaquePointer, _ tokens: inout [llama_token]) -> Bool {
        guard !tokens.isEmpty else { return true }
        return tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count))) == 0
        }
    }

    private func commonPrefixLength(_ a: [llama_token], _ b: [llama_token]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n, a[i] == b[i] { i += 1 }
        return i
    }

    private func tokenize(_ text: String, addBOS: Bool) throws -> [llama_token] {
        let byteLen = Int32(text.utf8.count)
        let nMax = byteLen + 16
        var result = [llama_token](repeating: 0, count: Int(nMax))
        let n = text.withCString { cstr in
            llama_tokenize(vocab, cstr, byteLen, &result, nMax, addBOS, true)
        }
        if n < 0 {
            var bigger = [llama_token](repeating: 0, count: Int(-n))
            let n2 = text.withCString { cstr in
                llama_tokenize(vocab, cstr, byteLen, &bigger, -n, addBOS, true)
            }
            guard n2 > 0 else { throw LlamaError.tokenize }
            return Array(bigger.prefix(Int(n2)))
        }
        return Array(result.prefix(Int(n)))
    }

    private func piece(_ token: llama_token) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            _ = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
            return String(cString: buf)
        }
        let bytes = buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
#endif
