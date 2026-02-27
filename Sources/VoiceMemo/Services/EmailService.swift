import Foundation

enum EmailError: Error, LocalizedError {
    case invalidURL
    case missingConfiguration
    case serverError(statusCode: Int)
    case networkError(Error)
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Gateway URL"
        case .missingConfiguration: return "Missing email configuration (URL, Token, or Recipient)"
        case .serverError(let code): return "Email server returned error: \(code)"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .invalidResponse: return "Invalid response from server"
        }
    }
}

class EmailService {
    private let settings: SettingsStore
    
    init(settings: SettingsStore) {
        self.settings = settings
    }
    
    func sendEmail(subject: String, body: String, attachmentPath: String?) async throws {
        // 1. Validation
        let gatewayUrlString = settings.fastmailUrl
        let token = settings.getFastmailToken()
        let recipient = settings.recipientEmail
        
        guard !gatewayUrlString.isEmpty,
              let token = token, !token.isEmpty,
              !recipient.isEmpty else {
            throw EmailError.missingConfiguration
        }
        
        guard let url = URL(string: gatewayUrlString.trimmingCharacters(in: .whitespacesAndNewlines))?.appendingPathComponent("/api/v1/send") else {
            throw EmailError.invalidURL
        }
        
        // 2. Build Request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var httpBody = Data()
        
        // Helper to append strings
        func append(_ string: String) {
            if let data = string.data(using: .utf8) {
                httpBody.append(data)
            }
        }
        
        // Helper to append fields
        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        
        // Add Fields
        appendField(name: "to", value: recipient)
        appendField(name: "subject", value: subject)
        appendField(name: "body", value: body)
        
        // Add Attachment
        if let attachmentPath = attachmentPath, FileManager.default.fileExists(atPath: attachmentPath) {
            let fileUrl = URL(fileURLWithPath: attachmentPath)
            let filename = fileUrl.lastPathComponent
            let mimeType = "text/markdown"
            
            if let fileData = try? Data(contentsOf: fileUrl) {
                append("--\(boundary)\r\n")
                append("Content-Disposition: form-data; name=\"attachments\"; filename=\"\(filename)\"\r\n")
                append("Content-Type: \(mimeType)\r\n\r\n")
                httpBody.append(fileData)
                append("\r\n")
            }
        }
        
        append("--\(boundary)--\r\n")
        request.httpBody = httpBody
        
        // 3. Send Request
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw EmailError.invalidResponse
            }
            
            if !(200...299).contains(httpResponse.statusCode) {
                throw EmailError.serverError(statusCode: httpResponse.statusCode)
            }
        } catch let error as EmailError {
            throw error
        } catch {
            throw EmailError.networkError(error)
        }
    }
}
