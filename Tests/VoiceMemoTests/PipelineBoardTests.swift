import XCTest
@testable import VoiceMemo

final class PipelineBoardTests: XCTestCase {
    
    func testPipelineBoardInitialization() {
        let board = PipelineBoard(
            recordingId: "test-recording-123",
            creationDate: Date(),
            mode: .mixed,
            config: PipelineBoard.Config(
                ossPrefix: "test-prefix",
                tingwuAppKey: "test-app-key",
                enableSummarization: true,
                enableMeetingAssistance: true,
                enableSpeakerDiarization: false,
                speakerCount: 0
            )
        )
        
        XCTAssertEqual(board.recordingId, "test-recording-123")
        XCTAssertEqual(board.mode, .mixed)
        XCTAssertEqual(board.config.ossPrefix, "test-prefix")
        XCTAssertEqual(board.config.tingwuAppKey, "test-app-key")
        XCTAssertTrue(board.config.enableSummarization)
        XCTAssertTrue(board.config.enableMeetingAssistance)
        XCTAssertFalse(board.config.enableSpeakerDiarization)
        XCTAssertEqual(board.config.speakerCount, 0)
        XCTAssertTrue(board.channels.isEmpty)
    }
    
    func testUpdateChannelCreatesNewChannel() {
        var board = createTestBoard()
        
        board.updateChannel(0) { channel in
            channel.rawAudioPath = "/tmp/test.m4a"
        }
        
        XCTAssertNotNil(board.channels[0])
        XCTAssertEqual(board.channels[0]?.rawAudioPath, "/tmp/test.m4a")
    }
    
    func testUpdateChannelModifiesExistingChannel() {
        var board = createTestBoard()
        
        board.updateChannel(0) { channel in
            channel.rawAudioPath = "/tmp/test.m4a"
        }
        
        board.updateChannel(0) { channel in
            channel.processedAudioPath = "/tmp/test_48k.m4a"
        }
        
        XCTAssertEqual(board.channels[0]?.rawAudioPath, "/tmp/test.m4a")
        XCTAssertEqual(board.channels[0]?.processedAudioPath, "/tmp/test_48k.m4a")
    }
    
    func testMultipleChannels() {
        var board = createTestBoard()
        
        board.updateChannel(0) { channel in
            channel.rawAudioPath = "/tmp/mixed.m4a"
        }
        
        board.updateChannel(1) { channel in
            channel.rawAudioPath = "/tmp/speaker1.m4a"
        }
        
        board.updateChannel(2) { channel in
            channel.rawAudioPath = "/tmp/speaker2.m4a"
        }
        
        XCTAssertEqual(board.channels.count, 3)
        XCTAssertEqual(board.channels[0]?.rawAudioPath, "/tmp/mixed.m4a")
        XCTAssertEqual(board.channels[1]?.rawAudioPath, "/tmp/speaker1.m4a")
        XCTAssertEqual(board.channels[2]?.rawAudioPath, "/tmp/speaker2.m4a")
    }
    
    func testChannelDataCompleteFlow() {
        var board = createTestBoard()
        
        board.updateChannel(0) { channel in
            channel.rawAudioPath = "/tmp/test.m4a"
            channel.rawAudioOssURL = "https://oss.example.com/test.m4a"
            channel.processedAudioPath = "/tmp/test_48k.m4a"
            channel.processedAudioOssURL = "https://oss.example.com/test_48k.m4a"
            channel.tingwuTaskId = "task-123"
            channel.tingwuTaskStatus = "RUNNING"
        }
        
        let channel = board.channels[0]
        XCTAssertNotNil(channel)
        XCTAssertEqual(channel?.rawAudioPath, "/tmp/test.m4a")
        XCTAssertEqual(channel?.rawAudioOssURL, "https://oss.example.com/test.m4a")
        XCTAssertEqual(channel?.processedAudioPath, "/tmp/test_48k.m4a")
        XCTAssertEqual(channel?.processedAudioOssURL, "https://oss.example.com/test_48k.m4a")
        XCTAssertEqual(channel?.tingwuTaskId, "task-123")
        XCTAssertEqual(channel?.tingwuTaskStatus, "RUNNING")
    }
    
    func testFormattedDatePath() {
        let date = Date(timeIntervalSince1970: 1640995200)
        let board = PipelineBoard(
            recordingId: "test",
            creationDate: date,
            mode: .mixed,
            config: PipelineBoard.Config(
                ossPrefix: "test",
                tingwuAppKey: "test",
                enableSummarization: false,
                enableMeetingAssistance: false,
                enableSpeakerDiarization: false,
                speakerCount: 0
            )
        )
        
        let path = board.formattedDatePath()
        XCTAssertEqual(path, "2022/01/01")
    }
    
    func testChannelDataErrorTracking() {
        var board = createTestBoard()
        
        board.updateChannel(0) { channel in
            channel.lastError = "Upload failed"
            channel.failedStep = .uploadingRaw
        }
        
        let channel = board.channels[0]
        XCTAssertNotNil(channel)
        XCTAssertEqual(channel?.lastError, "Upload failed")
        XCTAssertEqual(channel?.failedStep, .uploadingRaw)
    }
    
    func testChannelDataTranscript() {
        var board = createTestBoard()
        
        var result = TingwuResult()
        result.text = "Test transcript"
        result.summary = "Test summary"
        
        board.updateChannel(0) { channel in
            channel.transcript = result
        }
        
        let channel = board.channels[0]
        XCTAssertNotNil(channel)
        XCTAssertNotNil(channel?.transcript)
        XCTAssertEqual(channel?.transcript?.text, "Test transcript")
        XCTAssertEqual(channel?.transcript?.summary, "Test summary")
    }
    
    func testSeparatedModeConfiguration() {
        let board = PipelineBoard(
            recordingId: "test",
            creationDate: Date(),
            mode: .separated,
            config: PipelineBoard.Config(
                ossPrefix: "test",
                tingwuAppKey: "test",
                enableSummarization: false,
                enableMeetingAssistance: false,
                enableSpeakerDiarization: true,
                speakerCount: 2
            )
        )
        
        XCTAssertEqual(board.mode, .separated)
        XCTAssertTrue(board.config.enableSpeakerDiarization)
        XCTAssertEqual(board.config.speakerCount, 2)
    }
    
    private func createTestBoard() -> PipelineBoard {
        return PipelineBoard(
            recordingId: "test-recording",
            creationDate: Date(),
            mode: .mixed,
            config: PipelineBoard.Config(
                ossPrefix: "test-prefix",
                tingwuAppKey: "test-app-key",
                enableSummarization: true,
                enableMeetingAssistance: true,
                enableSpeakerDiarization: false,
                speakerCount: 0
            )
        )
    }
}
