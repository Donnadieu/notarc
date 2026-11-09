// Arc Max features (#58, #59) on Apple's built-in on-device model (FoundationModels, macOS 26 with Apple
// Intelligence turned on). NotArc supports macOS 13+, so every use is behind an availability check and the
// framework is weak-linked; on older systems or with Apple Intelligence off this reports "unavailable" and the
// callers fall back to their non-AI versions. Nothing here talks to a server.
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

@objc(NotArcOnDeviceModel)
public final class NotArcOnDeviceModel: NSObject {
  /// "available", or "unavailable:<reason>" where reason is os (older macOS), device (not eligible),
  /// off (Apple Intelligence turned off), notready (model still downloading) or other.
  @objc public static func availabilityDescription() -> String {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available:
        return "available"
      case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible: return "unavailable:device"
        case .appleIntelligenceNotEnabled: return "unavailable:off"
        case .modelNotReady: return "unavailable:notready"
        @unknown default: return "unavailable:other"
        }
      }
    }
    #endif
    return "unavailable:os"
  }

  /// One-shot request: a fresh session with `instructions`, answered with plain text. The completion runs on the
  /// main queue with either the text or an error description.
  @objc public static func respond(instructions: String, prompt: String,
                                   completion: @escaping (String?, String?) -> Void) {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      guard case .available = SystemLanguageModel.default.availability else {
        DispatchQueue.main.async { completion(nil, availabilityDescription()) }
        return
      }
      Task.detached(priority: .userInitiated) {
        do {
          let session = LanguageModelSession(instructions: instructions)
          // Greedy sampling: the same page and question give the same answer, and replies keep to the format asked for.
          let response = try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy))
          let text = response.content
          DispatchQueue.main.async { completion(text, nil) }
        } catch {
          let message = String(describing: error)
          DispatchQueue.main.async { completion(nil, message) }
        }
      }
      return
    }
    #endif
    DispatchQueue.main.async { completion(nil, "unavailable:os") }
  }
}
