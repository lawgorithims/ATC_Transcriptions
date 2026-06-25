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
/// NOTE: targets the modern llama.cpp C API (vocab-based functions + sampler chain, llama.cpp
/// b3900+/late-2024). If the package pinned in project.yml exposes different symbol names, this
/// one file is where they're adjusted — every other file is plain Foundation and unaffected.
final class LlamaContext: LLMEngine, @unchecked Sendable {
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let nThreads: Int32
    private let nCtx: UInt32
    private let queue = DispatchQueue(label: "net.atctranscribe.llama", qos: .utility)

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

    deinit { llama_model_free(model) }

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
        // A fresh context per call keeps peak memory low and decoding state clean.
        var cparams = llama_context_default_params()
        cparams.n_ctx = nCtx
        cparams.n_threads = nThreads
        cparams.n_threads_batch = nThreads
        guard let ctx = llama_init_from_model(model, cparams) else { throw LlamaError.contextInit }
        defer { llama_free(ctx) }

        var tokens = try tokenize(prompt, addBOS: true)
        guard !tokens.isEmpty else { throw LlamaError.tokenize }

        // Evaluate the prompt.
        let promptOK = tokens.withUnsafeMutableBufferPointer { buf -> Bool in
            let batch = llama_batch_get_one(buf.baseAddress, Int32(buf.count))
            return llama_decode(ctx, batch) == 0
        }
        guard promptOK else { throw LlamaError.decode }

        // Sampler chain: optional grammar (forces the JSON shape) then greedy (temperature 0).
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if let grammar {
            let g = grammar.withCString { gptr in "root".withCString { rptr in
                llama_sampler_init_grammar(vocab, gptr, rptr)
            } }
            if let g { llama_sampler_chain_add(sampler, g) }
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var output = ""
        var cur = llama_token()
        for _ in 0..<maxTokens {
            cur = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, cur) { break }
            llama_sampler_accept(sampler, cur)
            output += piece(cur)
            if stop.contains(where: { !$0.isEmpty && output.hasSuffix($0) }) {
                for s in stop where output.hasSuffix(s) { output.removeLast(s.count); break }
                break
            }
            // Feed the new token back in.
            var next = cur
            let ok = withUnsafeMutablePointer(to: &next) { ptr -> Bool in
                let batch = llama_batch_get_one(ptr, 1)
                return llama_decode(ctx, batch) == 0
            }
            if !ok { break }
        }
        return output
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
