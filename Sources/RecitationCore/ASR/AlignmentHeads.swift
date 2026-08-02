import CWhisper
import Foundation

/// The attention heads DTW reads word alignment from, which are specific to the weights.
public enum AlignmentHeads: String, Sendable, CaseIterable {
    case tiny, base, small, medium, largeV2, largeV3, largeV3Turbo

    var preset: whisper_alignment_heads_preset {
        switch self {
        case .tiny: return WHISPER_AHEADS_TINY
        case .base: return WHISPER_AHEADS_BASE
        case .small: return WHISPER_AHEADS_SMALL
        case .medium: return WHISPER_AHEADS_MEDIUM
        case .largeV2: return WHISPER_AHEADS_LARGE_V2
        case .largeV3: return WHISPER_AHEADS_LARGE_V3
        case .largeV3Turbo: return WHISPER_AHEADS_LARGE_V3_TURBO
        }
    }

    /// The preset for a model the app itself can select. A Quran-tuned model keeps the
    /// architecture of the checkpoint it was fine-tuned from, so its size decides this.
    public static func matching(_ size: SpeechModelConfiguration.Size) -> AlignmentHeads {
        switch size {
        case .tiny: return .tiny
        case .base: return .base
        case .small: return .small
        case .medium: return .medium
        }
    }

    /// Best guess from a weights filename, for tools that load a file directly.
    public static func inferred(fromFileNamed name: String) -> AlignmentHeads {
        let lowered = name.lowercased()
        if lowered.contains("large-v3-turbo") || lowered.contains("turbo") { return .largeV3Turbo }
        if lowered.contains("large-v3") { return .largeV3 }
        if lowered.contains("large") { return .largeV2 }
        if lowered.contains("medium") { return .medium }
        if lowered.contains("small") { return .small }
        if lowered.contains("tiny") { return .tiny }
        return .base
    }
}
