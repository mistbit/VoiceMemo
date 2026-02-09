import Foundation

struct SpeakerSegment: Codable, Equatable {
    let start: Double
    let end: Double
    let speakerId: String
}

struct TranscriptSegment: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

enum InferenceResult {
    case asr(ASRResult)
    case diarization(DiarizationResult)
}

struct ASRResult {
    let text: String
    let segments: [TranscriptSegment]
}

struct DiarizationResult {
    let segments: [SpeakerSegment]
}

struct FusedResult {
    let text: String
    let segments: [FusedSegment]
}

struct FusedSegment {
    let start: Double
    let end: Double
    let text: String
    let speaker: String
}

enum InferenceError: Error {
    case partialFailure
    case modelNotLoaded
    case processingFailed
}
