import Foundation

enum TranscriptionError: LocalizedError {
    case invalidCredentials
    case invalidAudioFormat(String)
    case taskTimeout
    case serviceUnavailable
    case invalidURL(String)
    case invalidResponse
    case taskCreationFailed(String)
    case taskQueryFailed(String)
    case networkError(Error)
    case parseError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid credentials"
        case .invalidAudioFormat(let format):
            return "Unsupported audio format: \(format)"
        case .taskTimeout:
            return "Task processing timeout"
        case .serviceUnavailable:
            return "Service temporarily unavailable"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidResponse:
            return "Invalid response from service"
        case .taskCreationFailed(let reason):
            return "Failed to create task: \(reason)"
        case .taskQueryFailed(let reason):
            return "Failed to query task: \(reason)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parseError(let reason):
            return "Failed to parse response: \(reason)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .invalidCredentials:
            return "Please check your credentials in settings"
        case .invalidAudioFormat(let format):
            return "Please use a supported audio format (m4a, mp3, wav, ogg). Current format: \(format)"
        case .taskTimeout:
            return "Please try again later or check task status manually"
        case .serviceUnavailable:
            return "Please try again later"
        case .invalidURL:
            return "Please check the URL configuration"
        case .invalidResponse:
            return "Please check the service status and try again"
        case .taskCreationFailed:
            return "Please check your input and try again"
        case .taskQueryFailed:
            return "Please check the task ID and try again"
        case .networkError:
            return "Please check your network connection"
        case .parseError:
            return "Please check the service response format"
        }
    }
}
