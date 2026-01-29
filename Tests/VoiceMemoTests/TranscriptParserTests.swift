import XCTest
@testable import VoiceMemo

final class TranscriptParserTests: XCTestCase {
    
    func testBuildTranscriptTextFromParagraphs() {
        let transcriptionData: [String: Any] = [
            "Paragraphs": [
                [
                    "SpeakerId": 1,
                    "Words": [
                        ["Text": "你好"],
                        ["Text": "世界"]
                    ]
                ],
                [
                    "SpeakerId": 2,
                    "Words": [
                        ["Text": "收到"]
                    ]
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "Speaker 1: 你好世界\nSpeaker 2: 收到")
    }
    
    func testBuildTranscriptTextFromSentences() {
        let transcriptionData: [String: Any] = [
            "Sentences": [
                [
                    "SpeakerId": 1,
                    "Text": "Hello world"
                ],
                [
                    "SpeakerId": 2,
                    "Text": "Goodbye"
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "Speaker 1: Hello world\nSpeaker 2: Goodbye")
    }
    
    func testBuildTranscriptTextFromTranscript() {
        let transcriptionData: [String: Any] = [
            "Transcript": "Simple transcript text"
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "Simple transcript text")
    }
    
    func testBuildTranscriptTextFromNestedResult() {
        let transcriptionData: [String: Any] = [
            "Result": [
                "Transcription": [
                    "Paragraphs": [
                        [
                            "SpeakerId": 1,
                            "Words": [
                                ["Text": "Nested"]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "Speaker 1: Nested")
    }
    
    func testBuildTranscriptTextFromDirectTranscription() {
        let transcriptionData: [String: Any] = [
            "Transcription": [
                "Paragraphs": [
                    [
                        "SpeakerId": 1,
                        "Words": [
                            ["Text": "Direct"]
                        ]
                    ]
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "Speaker 1: Direct")
    }
    
    func testBuildTranscriptTextWithSpeakerName() {
        let transcriptionData: [String: Any] = [
            "Paragraphs": [
                [
                    "SpeakerName": "Alice",
                    "Words": [
                        ["Text": "Hello"]
                    ]
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "Alice: Hello")
    }
    
    func testBuildTranscriptTextWithSpeaker() {
        let transcriptionData: [String: Any] = [
            "Paragraphs": [
                [
                    "Speaker": "Bob",
                    "Words": [
                        ["Text": "Hi"]
                    ]
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "Bob: Hi")
    }
    
    func testBuildTranscriptTextWithSpeakerID() {
        let transcriptionData: [String: Any] = [
            "Paragraphs": [
                [
                    "SpeakerID": 3,
                    "Words": [
                        ["Text": "Test"]
                    ]
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "Speaker 3: Test")
    }
    
    func testBuildTranscriptTextWithMixedCaseText() {
        let transcriptionData: [String: Any] = [
            "Paragraphs": [
                [
                    "SpeakerId": 1,
                    "Words": [
                        ["text": "lowercase"]
                    ]
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "Speaker 1: lowercase")
    }
    
    func testBuildTranscriptTextWithEmptyWords() {
        let transcriptionData: [String: Any] = [
            "Paragraphs": [
                [
                    "SpeakerId": 1,
                    "Words": []
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "")
    }
    
    func testBuildTranscriptTextWithEmptyParagraphs() {
        let transcriptionData: [String: Any] = [
            "Paragraphs": []
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "")
    }
    
    func testBuildTranscriptTextWithNoSpeaker() {
        let transcriptionData: [String: Any] = [
            "Paragraphs": [
                [
                    "Words": [
                        ["Text": "No speaker"]
                    ]
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "No speaker")
    }
    
    func testBuildTranscriptTextWithComplexStructure() {
        let transcriptionData: [String: Any] = [
            "Paragraphs": [
                [
                    "SpeakerId": 1,
                    "Words": [
                        ["Text": "First"],
                        ["Text": "sentence"],
                        ["Text": "from"],
                        ["Text": "speaker"],
                        ["Text": "one"]
                    ]
                ],
                [
                    "SpeakerId": 2,
                    "Words": [
                        ["Text": "Second"],
                        ["Text": "sentence"]
                    ]
                ],
                [
                    "SpeakerId": 1,
                    "Words": [
                        ["Text": "Third"],
                        ["Text": "sentence"]
                    ]
                ]
            ]
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertEqual(text, "Speaker 1: Firstsentencefromspeakerone\nSpeaker 2: Secondsentence\nSpeaker 1: Thirdsentence")
    }
    
    func testBuildTranscriptTextWithEmptyInput() {
        let text = TranscriptParser.buildTranscriptText(from: [:])
        XCTAssertNil(text)
    }
    
    func testBuildTranscriptTextWithUnknownStructure() {
        let transcriptionData: [String: Any] = [
            "UnknownField": "value"
        ]
        
        let text = TranscriptParser.buildTranscriptText(from: transcriptionData)
        XCTAssertNil(text)
    }
}
