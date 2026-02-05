import Foundation

struct TranscriptLine: Identifiable, Hashable, Codable {
    var id = UUID()
    let speaker: String?
    let text: String
    let startTime: Int? // In milliseconds
    let endTime: Int?   // In milliseconds
    
    // Helper to format as a single string
    var formattedString: String {
        if let speaker = speaker {
            return "\(speaker): \(text)"
        }
        return text
    }
}
