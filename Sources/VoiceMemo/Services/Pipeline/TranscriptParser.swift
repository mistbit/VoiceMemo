import Foundation

/// 转写结果解析器
/// 负责将听悟 API 返回的 JSON 数据解析为可读的文本格式
struct TranscriptParser {
    
    static func parse(from transcriptionData: [String: Any]) -> [TranscriptLine] {
        if let result = transcriptionData["Result"] as? [String: Any],
           let transcription = result["Transcription"] as? [String: Any] {
            return parse(from: transcription)
        }
        if let transcription = transcriptionData["Transcription"] as? [String: Any] {
            return parse(from: transcription)
        }
        if let paragraphs = transcriptionData["Paragraphs"] as? [[String: Any]] {
            return paragraphs.compactMap { createLine(from: $0) }
        }
        if let sentences = transcriptionData["Sentences"] as? [[String: Any]] {
            return sentences.compactMap { createLine(from: $0) }
        }
        if let transcript = transcriptionData["Transcript"] as? String {
            return [TranscriptLine(speaker: nil, text: transcript, startTime: nil, endTime: nil)]
        }
        return []
    }

    static func buildTranscriptText(from transcriptionData: [String: Any]) -> String? {
        let lines = parse(from: transcriptionData)
        if lines.isEmpty { return nil }
        return lines.map { $0.formattedString }.joined(separator: "\n")
    }
    
    private static func createLine(from item: [String: Any]) -> TranscriptLine? {
        let text = extractText(from: item)
        guard !text.isEmpty else { return nil }
        let speaker = extractSpeaker(from: item)
        let startTime = item["BeginTime"] as? Int ?? item["StartTime"] as? Int
        let endTime = item["EndTime"] as? Int
        return TranscriptLine(speaker: speaker, text: text, startTime: startTime, endTime: endTime)
    }

    private static func extractLine(from item: [String: Any]) -> String? {
        return createLine(from: item)?.formattedString
    }
    
    private static func extractText(from item: [String: Any]) -> String {
        if let text = item["Text"] as? String, !text.isEmpty { return text }
        if let text = item["text"] as? String, !text.isEmpty { return text }
        if let words = item["Words"] as? [[String: Any]] {
            return words.compactMap { $0["Text"] as? String ?? $0["text"] as? String }.joined()
        }
        return ""
    }
    
    private static func extractSpeaker(from item: [String: Any]) -> String? {
        if let name = item["SpeakerName"] as? String, !name.isEmpty { return name }
        if let name = item["Speaker"] as? String, !name.isEmpty { return name }
        if let id = item["SpeakerId"] ?? item["SpeakerID"] { return "Speaker \(id)" }
        return nil
    }
}
