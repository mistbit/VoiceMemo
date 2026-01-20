import Foundation
import AlibabaCloudOSS

class OSSService {
    private let settings: SettingsStore
    
    init(settings: SettingsStore) {
        self.settings = settings
    }
    
    func uploadFile(fileURL: URL, objectKey: String) async throws -> String {
        guard let akId = settings.getAccessKeyId(),
              let akSecret = settings.getAccessKeySecret() else {
            throw NSError(domain: "OSSService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing AccessKey"])
        }
        
        let endpoint = settings.ossEndpoint.hasPrefix("http") ? settings.ossEndpoint : "https://\(settings.ossEndpoint)"
        
        settings.log("OSS upload start: file=\(fileURL.path) bucket=\(settings.ossBucket) key=\(objectKey) region=\(settings.ossRegion) endpoint=\(endpoint)")
        
        let provider = StaticCredentialsProvider(accessKeyId: akId, accessKeySecret: akSecret)
        let config = Configuration.default()
            .withRegion(settings.ossRegion)
            .withEndpoint(endpoint)
            .withCredentialsProvider(provider)
            
        let client = Client(config)
        
        let request = PutObjectRequest(
            bucket: settings.ossBucket,
            key: objectKey,
            body: .file(fileURL)
        )
        
        do {
            let result = try await client.putObject(request)
            
            guard result.statusCode >= 200 && result.statusCode < 300 else {
                settings.log("OSS upload failed: status=\(result.statusCode)")
                throw NSError(domain: "OSSService", code: Int(result.statusCode), userInfo: [
                    NSLocalizedDescriptionKey: "Upload failed with status \(result.statusCode)"
                ])
            }
            
            var host = settings.ossEndpoint
            if host.hasPrefix("https://") {
                host = String(host.dropFirst(8))
            } else if host.hasPrefix("http://") {
                host = String(host.dropFirst(7))
            }
            
            let publicUrl = "https://\(settings.ossBucket).\(host)/\(objectKey)"
            settings.log("OSS upload success: url=\(publicUrl)")
            
            return publicUrl
        } catch {
            settings.log("OSS upload error: \(error.localizedDescription)")
            throw error
        }
    }
}
