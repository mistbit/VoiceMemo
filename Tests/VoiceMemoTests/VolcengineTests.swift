import XCTest
@testable import VoiceMemo

final class VolcengineTests: XCTestCase {
    
    func testServiceFactory() {
        let settings = SettingsStore()
        
        // Default is Tingwu
        settings.asrProvider = .tingwu
        let manager1 = MeetingPipelineManager(task: MeetingTask(recordingId: "1", localFilePath: "", title: ""), settings: settings)
        XCTAssertTrue(manager1.activeTranscriptionService is TingwuService)
        
        // Switch to Volcengine
        settings.asrProvider = .volcengine
        let manager2 = MeetingPipelineManager(task: MeetingTask(recordingId: "2", localFilePath: "", title: ""), settings: settings)
        XCTAssertTrue(manager2.activeTranscriptionService is VolcengineService)
    }
    
    func testTranscriptParsingFromUtterances() {
        // Test the new Volcengine format support in TranscriptParser
        
        let volcResponse: [String: Any] = [
            "utterances": [
                [
                    "text": "Hello World",
                    "start_time": 100,
                    "end_time": 200
                ],
                [
                    "text": "This is a test",
                    "start_time": 300,
                    "end_time": 400,
                    "speaker": "Alice"
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: volcResponse)
        XCTAssertEqual(text, "Hello World\nAlice: This is a test")
    }
    
    func testTranscriptParsingFromText() {
        let volcResponse: [String: Any] = [
            "text": "Full transcript text here."
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: volcResponse)
        XCTAssertEqual(text, "Full transcript text here.")
    }
}
