import Foundation

extension Notification.Name {
    static let meetingTaskDidUpdate = Notification.Name("meetingTaskDidUpdate")
    static let playbackShouldStop = Notification.Name("playbackShouldStop")
}

enum MeetingTaskStatus: String, Codable, CaseIterable, Hashable {
    case recorded      // 录音完成
    case uploadingRaw  // 上传原始文件中
    case uploadedRaw   // 原始文件上传完成
    case transcoding   // 转码中
    case transcoded    // 转码完成
    case uploading     // 上传中
    case uploaded      // 上传完成
    case created       // 任务创建中
    case polling       // 轮询中
    case completed     // 完成
    case failed        // 失败

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let status = MeetingTaskStatus(rawValue: rawValue) {
            self = status
        } else {
            switch rawValue {
            case "uploadingOriginal": self = .uploadingRaw
            case "uploadedOriginal": self = .uploadedRaw
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid status: \(rawValue)")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func from(rawValue: String) -> MeetingTaskStatus? {
        if let status = MeetingTaskStatus(rawValue: rawValue) {
            return status
        }
        switch rawValue {
        case "uploadingOriginal": return .uploadingRaw
        case "uploadedOriginal": return .uploadedRaw
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .recorded: return "Recorded"
        case .uploadingRaw: return "Up Raw"
        case .uploadedRaw: return "Raw Up"
        case .transcoding: return "Transcode"
        case .transcoded: return "Transcoded"
        case .uploading: return "Uploading"
        case .uploaded: return "Uploaded"
        case .created: return "Created"
        case .polling: return "Polling"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }
}

class MeetingTask: Identifiable, ObservableObject, Hashable, Codable {
    static let userInfoTaskKey = "task"
    
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var recordingId: String
    
    // File Paths
    var localFilePath: String // Mixed audio path
    var rawLocalFilePath: String? // Original local audio path
    
    var originalOssUrl: String? // Mixed Original OSS URL
    
    var ossUrl: String? // Mixed OSS URL
    
    // Transcription Info
    var transcriptionTaskId: String?
    
    var taskKey: String?
    var bizDuration: Int?
    var status: MeetingTaskStatus = .recorded
    var title: String
    
    // Results
    var transcript: String?
    
    var summary: String?
    var keyPoints: String?
    var actionItems: String?
    var outputMp3Path: String?
    
    // Error & Retry
    var lastError: String?
    var lastSuccessfulStatus: MeetingTaskStatus?
    var failedStep: MeetingTaskStatus?
    var retryCount: Int = 0
    
    // Complete Poll Results Storage
    var overviewData: String?
    var transcriptData: String?
    var rawData: String?
    
    init(recordingId: String, localFilePath: String, title: String) {
        self.recordingId = recordingId
        self.localFilePath = localFilePath
        self.title = title
    }
    
    static func == (lhs: MeetingTask, rhs: MeetingTask) -> Bool {
        return lhs.id == rhs.id &&
               lhs.status == rhs.status &&
               lhs.title == rhs.title
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(status)
        hasher.combine(title)
    }
}

extension MeetingTask {
    var inferredProvider: String {
        // Try to infer from raw data structure
        if let data = self.overviewData ?? self.rawData, !data.isEmpty {
            if data.contains("\"audio_info\"") {
                return "Volcengine"
            }
            if data.contains("\"TaskKey\"") || data.contains("\"MeetingAssistance\"") {
                return "Tingwu"
            }
        }
        
        // Fallback: Check if we have specific fields that might hint
        // This is a weak heuristic but better than nothing for legacy data
        if let _ = self.transcriptionTaskId {
             // Both use this field currently, so it's not decisive unless we check format
             // But if we have no raw data, we might assume Tingwu as it was the default/first
             return "Unknown"
        }
        
        return "Unknown"
    }
    
    var providerIcon: String {
        switch inferredProvider {
        case "Volcengine": return "waveform.path.ecg"
        case "Tingwu": return "waveform.circle"
        default: return "questionmark.circle"
        }
    }
}

extension MeetingTask {
    func markdownSummary() -> String {
        var md = "# \(title)\n\n"
        md += "Date: \(createdAt)\n\n"
        
        md += "## Task Info\n"
        if let key = taskKey { md += "- Task Key: \(key)\n" }
        if let duration = bizDuration { md += "- Duration: \(duration / 1000)s\n" }
        if let mp3 = outputMp3Path { md += "- Audio: [Download](\(mp3))\n" }
        md += "\n"
        
        if let summary = summary {
            md += "## Summary\n\(summary)\n\n"
        }
        
        if let keyPoints = keyPoints {
            md += "## Key Points\n\(keyPoints)\n\n"
        }
        
        if let actionItems = actionItems {
            md += "## Action Items\n\(actionItems)\n\n"
        }
        
        if let transcript = derivedTranscriptText() {
            md += "## Transcript\n\(transcript)\n"
        }
        
        return md
    }
    
    func derivedTranscriptText() -> String? {
        if let transcript = transcript, !transcript.isEmpty {
            return transcript
        }

        if let dataStr = transcriptData,
           let data = dataStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = TranscriptParser.buildTranscriptText(from: json) {
                return text
            }
        }

        return nil
    }
    
    func safeFilename() -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let parts = title.components(separatedBy: invalid)
        let name = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "meeting-summary" : name
    }
}
