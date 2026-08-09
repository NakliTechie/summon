#if canImport(llama)
import llama

/// Feasibility probe: proves the embedded llama.cpp xcframework resolves, links,
/// and its C API is callable from Swift. Superseded by the real rung.
enum LlamaCppProbe {
    static var maxDevices: Int { Int(llama_max_devices()) }
    static var supportsGPUOffload: Bool { llama_supports_gpu_offload() }
}
#endif
