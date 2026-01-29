import Foundation
import AVFoundation

struct PipelineContext {
    var task: MeetingTask
    let settings: SettingsStore
    let ossService: OSSService
    let tingwuService: TingwuService
    
    func log(_ message: String) {
        settings.log(message)
    }
}

protocol PipelineNode {
    var step: MeetingTaskStatus { get }
    func run(context: PipelineContext) async throws -> MeetingTask
}

class UploadOriginalNode: PipelineNode {
    let step: MeetingTaskStatus = .uploadingRaw
    let targetSpeaker: Int?
    
    init(targetSpeaker: Int? = nil) {
        self.targetSpeaker = targetSpeaker
    }
    
    func run(context: PipelineContext) async throws -> MeetingTask {
        context.log("UploadOriginalNode start: target=\(targetSpeaker ?? 0)")
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let datePath = formatter.string(from: context.task.createdAt)
        
        var fileURL: URL
        var objectKey: String
        
        if let spk = targetSpeaker {
            if spk == 1 {
                guard let path = context.task.speaker1AudioPath else { throw NSError(domain: "Pipeline", code: 404, userInfo: [NSLocalizedDescriptionKey: "Speaker 1 path missing"]) }
                fileURL = URL(fileURLWithPath: path)
                objectKey = "\(context.settings.ossPrefix)\(datePath)/\(context.task.recordingId)/speaker1_raw.m4a"
            } else {
                guard let path = context.task.speaker2AudioPath else { throw NSError(domain: "Pipeline", code: 404, userInfo: [NSLocalizedDescriptionKey: "Speaker 2 path missing"]) }
                fileURL = URL(fileURLWithPath: path)
                objectKey = "\(context.settings.ossPrefix)\(datePath)/\(context.task.recordingId)/speaker2_raw.m4a"
            }
        } else {
            fileURL = URL(fileURLWithPath: context.task.localFilePath)
            objectKey = "\(context.settings.ossPrefix)\(datePath)/\(context.task.recordingId)/mixed_raw.m4a"
        }
        
        let url = try await context.ossService.uploadFile(fileURL: fileURL, objectKey: objectKey)
        context.log("Upload Original success: \(url)")
        
        var updatedTask = context.task
        if let spk = targetSpeaker {
            if spk == 1 {
                updatedTask.originalOssUrl = url
            } else {
                updatedTask.speaker2OriginalOssUrl = url
            }
        } else {
            updatedTask.originalOssUrl = url
        }
        
        return updatedTask
    }
}

class TranscodeNode: PipelineNode {
    let step: MeetingTaskStatus = .transcoding
    let targetSpeaker: Int?
    
    init(targetSpeaker: Int? = nil) {
        self.targetSpeaker = targetSpeaker
    }
    
    func run(context: PipelineContext) async throws -> MeetingTask {
        context.log("TranscodeNode start: target=\(targetSpeaker ?? 0)")
        
        var inputPath: String?
        var outputPath: String
        
        if let spk = targetSpeaker {
            if spk == 1 {
                inputPath = context.task.speaker1AudioPath
                outputPath = URL(fileURLWithPath: inputPath ?? "").deletingLastPathComponent().appendingPathComponent("speaker1_48k.m4a").path
            } else {
                inputPath = context.task.speaker2AudioPath
                outputPath = URL(fileURLWithPath: inputPath ?? "").deletingLastPathComponent().appendingPathComponent("speaker2_48k.m4a").path
            }
        } else {
            inputPath = context.task.localFilePath
            outputPath = URL(fileURLWithPath: inputPath ?? "").deletingLastPathComponent().appendingPathComponent("mixed_48k.m4a").path
        }
        
        guard let input = inputPath, !input.isEmpty else {
            throw NSError(domain: "Pipeline", code: 404, userInfo: [NSLocalizedDescriptionKey: "Input file path missing"])
        }
        
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: outputPath)
        
        if await performTranscode(input: inputURL, output: outputURL, context: context) {
            var updatedTask = context.task
            if let spk = targetSpeaker {
                if spk == 1 {
                    updatedTask.speaker1AudioPath = outputPath
                    updatedTask.localFilePath = outputPath
                } else {
                    updatedTask.speaker2AudioPath = outputPath
                }
            } else {
                updatedTask.localFilePath = outputPath
            }
            return updatedTask
        } else {
            throw NSError(domain: "Pipeline", code: 500, userInfo: [NSLocalizedDescriptionKey: "Transcode failed"])
        }
    }
    
    private func performTranscode(input: URL, output: URL, context: PipelineContext) async -> Bool {
        try? FileManager.default.removeItem(at: output)
        
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: input.path)
            if let size = attrs[.size] as? UInt64, size == 0 {
                context.log("Transcode failed: Input file \(input.lastPathComponent) is empty (0 bytes)")
                return false
            }
        } catch {
            context.log("Transcode failed: Cannot access input file \(input.lastPathComponent): \(error.localizedDescription)")
            return false
        }

        let asset = AVAsset(url: input)
        
        do {
            let isReadable = try await asset.load(.isReadable)
            if !isReadable {
                context.log("Transcode failed: Input file \(input.lastPathComponent) is not readable by AVAsset")
                return false
            }
        } catch {
            context.log("Transcode failed: Failed to load asset metadata for \(input.lastPathComponent): \(error.localizedDescription)")
            return false
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            context.log("Transcode failed: cannot create export session for \(input.lastPathComponent)")
            return false
        }
        
        exportSession.outputURL = output
        exportSession.outputFileType = .m4a
        await exportSession.export()
        
        if exportSession.status == .completed {
            return true
        } else {
            let err = exportSession.error?.localizedDescription ?? "Unknown error"
            context.log("Transcode failed for \(input.lastPathComponent): \(err)")
            return false
        }
    }
}

class UploadNode: PipelineNode {
    let step: MeetingTaskStatus = .uploading
    let targetSpeaker: Int?
    
    init(targetSpeaker: Int? = nil) {
        self.targetSpeaker = targetSpeaker
    }
    
    func run(context: PipelineContext) async throws -> MeetingTask {
        context.log("UploadNode start: target=\(targetSpeaker ?? 0)")
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let datePath = formatter.string(from: context.task.createdAt)
        
        var fileURL: URL
        var objectKey: String
        
        if let spk = targetSpeaker {
            if spk == 1 {
                guard let path = context.task.speaker1AudioPath else { throw NSError(domain: "Pipeline", code: 404, userInfo: [NSLocalizedDescriptionKey: "Speaker 1 path missing"]) }
                fileURL = URL(fileURLWithPath: path)
                objectKey = "\(context.settings.ossPrefix)\(datePath)/\(context.task.recordingId)/speaker1.m4a"
            } else {
                guard let path = context.task.speaker2AudioPath else { throw NSError(domain: "Pipeline", code: 404, userInfo: [NSLocalizedDescriptionKey: "Speaker 2 path missing"]) }
                fileURL = URL(fileURLWithPath: path)
                objectKey = "\(context.settings.ossPrefix)\(datePath)/\(context.task.recordingId)/speaker2.m4a"
            }
        } else {
            fileURL = URL(fileURLWithPath: context.task.localFilePath)
            objectKey = "\(context.settings.ossPrefix)\(datePath)/\(context.task.recordingId)/mixed.m4a"
        }
        
        let url = try await context.ossService.uploadFile(fileURL: fileURL, objectKey: objectKey)
        context.log("Upload success: \(url)")
        
        var updatedTask = context.task
        if let spk = targetSpeaker {
            if spk == 1 {
                updatedTask.ossUrl = url
            } else {
                updatedTask.speaker2OssUrl = url
            }
        } else {
            updatedTask.ossUrl = url
        }
        
        return updatedTask
    }
}

class CreateTaskNode: PipelineNode {
    let step: MeetingTaskStatus = .created
    let targetSpeaker: Int?
    
    init(targetSpeaker: Int? = nil) {
        self.targetSpeaker = targetSpeaker
    }
    
    func run(context: PipelineContext) async throws -> MeetingTask {
        context.log("CreateTaskNode start: target=\(targetSpeaker ?? 0)")
        
        var fileUrl: String?
        if let spk = targetSpeaker {
            if spk == 1 {
                fileUrl = context.task.ossUrl
            } else {
                fileUrl = context.task.speaker2OssUrl
            }
        } else {
            fileUrl = context.task.ossUrl
        }
        
        guard let url = fileUrl else {
            throw NSError(domain: "Pipeline", code: 404, userInfo: [NSLocalizedDescriptionKey: "OSS URL missing"])
        }
        
        let taskId = try await context.tingwuService.createTask(fileUrl: url)
        context.log("Create task success: \(taskId)")
        
        var updatedTask = context.task
        if let spk = targetSpeaker {
            if spk == 1 {
                updatedTask.tingwuTaskId = taskId
            } else {
                updatedTask.speaker2TingwuTaskId = taskId
            }
        } else {
            updatedTask.tingwuTaskId = taskId
        }
        
        return updatedTask
    }
}

class PollingNode: PipelineNode {
    let step: MeetingTaskStatus = .polling
    let targetSpeaker: Int?
    
    init(targetSpeaker: Int? = nil) {
        self.targetSpeaker = targetSpeaker
    }
    
    func run(context: PipelineContext) async throws -> MeetingTask {
        context.log("PollingNode start: target=\(targetSpeaker ?? 0)")
        
        var taskId: String?
        if let spk = targetSpeaker {
            if spk == 1 {
                taskId = context.task.tingwuTaskId
            } else {
                taskId = context.task.speaker2TingwuTaskId
            }
        } else {
            taskId = context.task.tingwuTaskId
        }
        
        guard let id = taskId else {
            throw NSError(domain: "Pipeline", code: 404, userInfo: [NSLocalizedDescriptionKey: "Task ID missing"])
        }
        
        let (status, data) = try await context.tingwuService.getTaskInfo(taskId: id)
        context.log("Poll status: \(status)")
        
        var updatedTask = context.task
        
        if status == "SUCCESS" || status == "COMPLETED" {
            if let result = data?["Result"] as? [String: Any] {
                if targetSpeaker == nil {
                    updatedTask.status = .completed
                    updateMetadata(task: &updatedTask, data: data, result: result)
                    if let transcript = await fetchTranscript(from: result, service: context.tingwuService) {
                        updatedTask.transcript = transcript
                    }
                    await updateSummary(task: &updatedTask, result: result, service: context.tingwuService)
                } else {
                    if targetSpeaker == 1 {
                        updatedTask.speaker1Status = .completed
                        if let transcript = await fetchTranscript(from: result, service: context.tingwuService) {
                            updatedTask.speaker1Transcript = transcript
                        }
                    } else {
                        updatedTask.speaker2Status = .completed
                        if let transcript = await fetchTranscript(from: result, service: context.tingwuService) {
                            updatedTask.speaker2Transcript = transcript
                        }
                    }
                }
            }
            return updatedTask
        } else if status == "FAILED" {
            if let data = data {
                if let taskKey = data["TaskKey"] as? String { updatedTask.taskKey = taskKey }
                if let taskStatus = data["TaskStatus"] as? String { updatedTask.apiStatus = taskStatus }
                if let statusText = data["StatusText"] as? String { updatedTask.statusText = statusText }
            }
            throw NSError(domain: "Pipeline", code: 500, userInfo: [NSLocalizedDescriptionKey: "Cloud task failed: \(updatedTask.statusText ?? "Unknown")"])
        } else {
            throw NSError(domain: "Pipeline", code: 202, userInfo: [NSLocalizedDescriptionKey: "Task running"])
        }
    }
    
    private func updateMetadata(task: inout MeetingTask, data: [String: Any]?, result: [String: Any]) {
        if let taskKey = data?["TaskKey"] as? String { task.taskKey = taskKey }
        if let taskStatus = data?["TaskStatus"] as? String { task.apiStatus = taskStatus }
        if let statusText = data?["StatusText"] as? String { task.statusText = statusText }
        if let bizDuration = data?["BizDuration"] as? Int { task.bizDuration = bizDuration }
        if let outputMp3Path = result["OutputMp3Path"] as? String { task.outputMp3Path = outputMp3Path }
        
        if let data = data, let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
            task.rawResponse = String(data: jsonData, encoding: .utf8)
        }
    }
    
    private func updateSummary(task: inout MeetingTask, result: [String: Any], service: TingwuService) async {
        if let summarizationUrl = result["Summarization"] as? String {
            if let summarizationData = try? await service.fetchJSON(url: summarizationUrl) {
                if let summarizationObj = summarizationData["Summarization"] as? [String: Any] {
                    if let summary = summarizationObj["ParagraphTitle"] as? String {
                        task.summary = summary
                    }
                    if let summaryText = summarizationObj["ParagraphSummary"] as? String {
                        task.summary = (task.summary ?? "") + "\n\n" + summaryText
                    }
                }
            }
        }
    }
    
    private func fetchTranscript(from result: [String: Any], service: TingwuService) async -> String? {
        var transcriptText: String?
        if let transcriptionUrl = result["Transcription"] as? String {
            do {
                let transcriptionData = try await service.fetchJSON(url: transcriptionUrl)
                transcriptText = buildTranscriptText(from: transcriptionData)
            } catch {
                print("Failed to download transcript")
            }
        } else if let transcriptionObj = result["Transcription"] as? [String: Any] {
            transcriptText = buildTranscriptText(from: transcriptionObj)
        }
        
        if transcriptText == nil {
            if let paragraphs = result["Paragraphs"] as? [[String: Any]] {
                transcriptText = buildTranscriptText(from: ["Paragraphs": paragraphs])
            } else if let sentences = result["Sentences"] as? [[String: Any]] {
                transcriptText = buildTranscriptText(from: ["Sentences": sentences])
            } else if let transcriptInline = result["Transcript"] as? String {
                transcriptText = transcriptInline
            }
        }
        return transcriptText
    }
    
    private func buildTranscriptText(from transcriptionData: [String: Any]) -> String? {
        if let result = transcriptionData["Result"] as? [String: Any],
           let transcription = result["Transcription"] as? [String: Any] {
            return buildTranscriptText(from: transcription)
        }
        if let transcription = transcriptionData["Transcription"] as? [String: Any] {
            return buildTranscriptText(from: transcription)
        }
        if let paragraphs = transcriptionData["Paragraphs"] as? [[String: Any]] {
            return paragraphs.compactMap { extractLine(from: $0) }.joined(separator: "\n")
        }
        if let sentences = transcriptionData["Sentences"] as? [[String: Any]] {
            return sentences.compactMap { extractLine(from: $0) }.joined(separator: "\n")
        }
        if let transcript = transcriptionData["Transcript"] as? String {
            return transcript
        }
        return nil
    }
    
    private func extractLine(from item: [String: Any]) -> String? {
        let speaker = extractSpeaker(from: item)
        let text = extractText(from: item)
        guard !text.isEmpty else { return nil }
        if let speaker {
            return "\(speaker): \(text)"
        }
        return text
    }
    
    private func extractText(from item: [String: Any]) -> String {
        if let text = item["Text"] as? String, !text.isEmpty { return text }
        if let text = item["text"] as? String, !text.isEmpty { return text }
        if let words = item["Words"] as? [[String: Any]] {
            return words.compactMap { $0["Text"] as? String ?? $0["text"] as? String }.joined()
        }
        return ""
    }
    
    private func extractSpeaker(from item: [String: Any]) -> String? {
        if let name = item["SpeakerName"] as? String, !name.isEmpty { return name }
        if let name = item["Speaker"] as? String, !name.isEmpty { return name }
        if let id = item["SpeakerId"] ?? item["SpeakerID"] { return "Speaker \(id)" }
        return nil
    }
}
