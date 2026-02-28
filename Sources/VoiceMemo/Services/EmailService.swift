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
    
    // Helper for testing
    static func parseRecipients(_ raw: String) -> String {
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }

    func sendEmail(subject: String, body: String, attachmentPaths: [String]?) async throws {
        let gatewayUrlString = settings.fastmailUrl
        let token = settings.getFastmailToken()
        let rawRecipients = settings.recipientEmail

        // Clean up and validate recipients
        let recipients = Self.parseRecipients(rawRecipients)

        guard !gatewayUrlString.isEmpty,
              let token = token, !token.isEmpty,
              !recipients.isEmpty else {
            throw EmailError.missingConfiguration
        }

        guard let url = URL(string: gatewayUrlString.trimmingCharacters(in: .whitespacesAndNewlines))?.appendingPathComponent("/api/v1/send") else {
            throw EmailError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var httpBody = Data()

        func append(_ string: String) {
            if let data = string.data(using: .utf8) {
                httpBody.append(data)
            }
        }

        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        func appendFile(path: String) {
            let fileUrl = URL(fileURLWithPath: path)
            let filename = fileUrl.lastPathComponent
            let fileExtension = fileUrl.pathExtension.lowercased()
            let mimeType = mimeTypeForExtension(fileExtension)

            if let fileData = try? Data(contentsOf: fileUrl) {
                append("--\(boundary)\r\n")
                append("Content-Disposition: form-data; name=\"attachments\"; filename=\"\(filename)\"\r\n")
                append("Content-Type: \(mimeType)\r\n\r\n")
                httpBody.append(fileData)
                append("\r\n")
            }
        }

        appendField(name: "to", value: recipients)
        appendField(name: "subject", value: subject)
        appendField(name: "body", value: body)

        // Attach files
        if let attachmentPaths = attachmentPaths {
            for path in attachmentPaths {
                if FileManager.default.fileExists(atPath: path) {
                    appendFile(path: path)
                }
            }
        }

        append("--\(boundary)--\r\n")
        request.httpBody = httpBody

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

    // Helper method for backward compatibility
    func sendEmail(subject: String, body: String, attachmentPath: String?) async throws {
        let paths = attachmentPath != nil ? [attachmentPath!] : nil
        try await sendEmail(subject: subject, body: body, attachmentPaths: paths)
    }

    private func mimeTypeForExtension(_ fileExtension: String) -> String {
        switch fileExtension {
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        case "json": return "application/json"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }
}
