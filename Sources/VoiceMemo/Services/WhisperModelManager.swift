import Foundation
@preconcurrency import WhisperKit
import Combine

class WhisperModelManager: ObservableObject, @unchecked Sendable {
    static let shared = WhisperModelManager()
    
    @Published var currentModelName: String = "base"
    @Published var isModelLoading: Bool = false
    @Published var loadingError: String?
    @Published var availableModels: [String] = [
        "tiny", "base", "small", "medium", "large-v3", "distil-large-v3"
    ]
    
    // Download progress tracking
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading: Bool = false
    @Published var downloadedModels: Set<String> = []
    
    // Public accessor for the current active pipe (for backward compatibility/simplicity)
    var pipe: WhisperKit? {
        get {
            // Return the pipe for currentModelName if loaded
            if case .loaded(let p, _) = models[currentModelName] { return p }
            if case .cached(let p, _) = models[currentModelName] { return p }
            return nil
        }
    }
    
    enum ModelInstance {
        case unloaded
        case cached(pipe: WhisperKit, lastUsed: Date)
        case loaded(pipe: WhisperKit, inUseCount: Int)
    }
    
    private var models: [String: ModelInstance] = [:]
    private let cacheTimeout: TimeInterval = 300 // 5 minutes
    private let queue = DispatchQueue(label: "com.voicememo.modelmanager", attributes: .concurrent)
    
    private init() {
        // Start cleanup timer
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupExpiredModels()
        }
        
        // Initial check
        refreshDownloadedStatus()
    }
    
    func refreshDownloadedStatus() {
        // Run on background queue to avoid blocking main thread with file I/O
        queue.async {
            var downloaded = Set<String>()
            for model in self.availableModels {
                if self.isModelDownloaded(model) {
                    downloaded.insert(model)
                }
            }
            Task { @MainActor in
                self.downloadedModels = downloaded
            }
        }
    }
    
    private func formatModelName(_ name: String) -> String {
        if !name.contains("openai_whisper-") {
            return "openai_whisper-\(name)"
        }
        return name
    }
    
    private func getPaths() -> (storage: URL, repo: URL, snapshots: URL) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelStoragePath = appSupport.appendingPathComponent("VoiceMemo/Models")
        
        let repoName = "argmaxinc/whisperkit-coreml"
        let repoDirName = "models--" + repoName.replacingOccurrences(of: "/", with: "--")
        let repoPath = modelStoragePath.appendingPathComponent(repoDirName)
        let snapshotsPath = repoPath.appendingPathComponent("snapshots")
        
        return (modelStoragePath, repoPath, snapshotsPath)
    }
    
    func isModelDownloaded(_ name: String) -> Bool {
        let modelName = formatModelName(name)
        let paths = getPaths()
        
        print("[WhisperModelManager] Checking status for \(name) (variant: \(modelName))...")
        
        guard let snapshotContents = try? FileManager.default.contentsOfDirectory(at: paths.snapshots, includingPropertiesForKeys: nil) else {
             print("[WhisperModelManager] Check \(name): No snapshots directory found at \(paths.snapshots.path)")
             return false
        }
        
        // Iterate through all snapshot directories (usually just one for the main branch)
        for snapshot in snapshotContents {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: snapshot.path, isDirectory: &isDir), isDir.boolValue else { continue }
            
            // Search specifically for the model variant folder or file
            // WhisperKit structure: .../snapshots/<hash>/<variant>/...
            // So we look for a directory with the variant name
            
            // Optimization: First check if a directory with the exact model name exists at the top level of the snapshot
            let exactPath = snapshot.appendingPathComponent(modelName)
            if FileManager.default.fileExists(atPath: exactPath.path) {
                print("[WhisperModelManager] Check \(name): Found exact match at \(exactPath.path)")
                return true
            }
            
            // Fallback: Recursive search (in case of different structure)
            if let enumerator = FileManager.default.enumerator(at: snapshot, includingPropertiesForKeys: nil) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if fileURL.lastPathComponent == modelName || fileURL.path.contains("/\(modelName)/") {
                        print("[WhisperModelManager] Check \(name): Found artifact at \(fileURL.path)")
                        return true
                    }
                }
            }
        }
        
        print("[WhisperModelManager] Check \(name): No artifacts found in snapshots")
        return false
    }
    
    func downloadModel(_ name: String) async throws {
        let modelName = formatModelName(name)
        
        await MainActor.run {
            self.isDownloading = true
            self.downloadProgress = 0.0
            self.loadingError = nil
            self.currentModelName = modelName
        }
        
        do {
            let paths = getPaths()
            try? FileManager.default.createDirectory(at: paths.storage, withIntermediateDirectories: true)
            
            print("[WhisperModelManager] Starting explicit download for: \(modelName)")
            
            let useMirror = UserDefaults.standard.bool(forKey: "useHFMirror")
            if useMirror {
                print("[WhisperModelManager] Using HF Mirror")
                setenv("HF_ENDPOINT", "https://hf-mirror.com", 1)
            } else {
                unsetenv("HF_ENDPOINT")
            }
            
            _ = try await WhisperKit.download(
                variant: modelName,
                downloadBase: paths.storage,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: { progress in
                    print("[WhisperModelManager] Download progress: \(progress.fractionCompleted) (completed: \(progress.completedUnitCount), total: \(progress.totalUnitCount))")
                    Task { @MainActor in
                        self.downloadProgress = progress.fractionCompleted
                    }
                }
            )
            
            await MainActor.run {
                self.isDownloading = false
                self.downloadProgress = 1.0
            }
            print("[WhisperModelManager] Download complete for: \(modelName)")
            
            // Auto-load after download
            try await loadModel(name)
            refreshDownloadedStatus()
            
        } catch {
            print("[WhisperModelManager] Download failed: \(error)")
            await MainActor.run {
                self.isDownloading = false
                self.loadingError = error.localizedDescription
            }
            throw error
        }
    }
    
    func deleteModel() {
        let paths = getPaths()
        print("[WhisperModelManager] Deleting all models at: \(paths.repo.path)")
        
        if FileManager.default.fileExists(atPath: paths.repo.path) {
            try? FileManager.default.removeItem(at: paths.repo)
        }
        
        // Also clean global cache to be safe
        let globalCachePath = paths.storage.appendingPathComponent(".cache/huggingface")
        if FileManager.default.fileExists(atPath: globalCachePath.path) {
            try? FileManager.default.removeItem(at: globalCachePath)
        }
        
        // Reset state
        Task { @MainActor in
            self.downloadProgress = 0.0
            self.isDownloading = false
        }
        refreshDownloadedStatus()
    }

    func loadModel(_ name: String) async throws {
        // Increase initial retry count to handle timeouts with resumption
        try await loadModel(name, retryCount: 5)
    }

    private func loadModel(_ name: String, retryCount: Int) async throws {
        let modelName = formatModelName(name)
        
        // Check if already loaded or cached
        var shouldLoad = false
        queue.sync {
            if let instance = models[modelName] {
                switch instance {
                case .loaded(let p, let count):
                    models[modelName] = .loaded(pipe: p, inUseCount: count + 1)
                case .cached(let p, _):
                    models[modelName] = .loaded(pipe: p, inUseCount: 1)
                case .unloaded:
                    shouldLoad = true
                }
            } else {
                shouldLoad = true
            }
        }
        
        if !shouldLoad {
            await MainActor.run { self.currentModelName = modelName }
            return
        }
        
        await MainActor.run {
            self.isModelLoading = true
            self.loadingError = nil
            self.currentModelName = modelName
        }
        
        do {
            print("[WhisperModelManager] Loading model: \(modelName) (Remaining retries: \(retryCount))")
            
            let useMirror = UserDefaults.standard.bool(forKey: "useHFMirror")
            print("[WhisperModelManager] Configuration - Model: \(modelName), UseMirror: \(useMirror)")
            
            let config = WhisperKitConfig(model: modelName)
            config.verbose = true
            config.logLevel = .debug
            
            if useMirror {
                print("[WhisperModelManager] Using HF Mirror: https://hf-mirror.com")
                setenv("HF_ENDPOINT", "https://hf-mirror.com", 1)
            } else {
                print("[WhisperModelManager] Using Default Source (Hugging Face)")
                unsetenv("HF_ENDPOINT")
            }
            
            // Use helper for paths
            let paths = getPaths()
            try? FileManager.default.createDirectory(at: paths.storage, withIntermediateDirectories: true)
            
            config.downloadBase = paths.storage
            print("[WhisperModelManager] Final Download Base: \(paths.storage.path)")
            let repoName = config.modelRepo ?? "argmaxinc/whisperkit-coreml"
            print("[WhisperModelManager] Model Repo: \(repoName)")
            
            // Try to initialize WhisperKit
            let newPipe: WhisperKit
            do {
                newPipe = try await WhisperKit(config)
            } catch {
                print("[WhisperModelManager] Load attempt failed: \(error)")
                
                let errorString = "\(error)"
                let isTimeout = errorString.contains("timed out")
                let isMetadataError = errorString.contains("Invalid metadata") || errorString.contains("File metadata")
                
                // Helper to check for local model existence
                // Use paths from helper
                let repoPath = paths.repo
                let snapshotsPath = paths.snapshots
                
                var hasLocalModel = false
                if let snapshotContents = try? FileManager.default.contentsOfDirectory(at: snapshotsPath, includingPropertiesForKeys: nil),
                   !snapshotContents.isEmpty {
                    print("[WhisperModelManager] Found local snapshots: \(snapshotContents.map { $0.lastPathComponent })")
                    hasLocalModel = true
                }
                
                // Strategy 1: Offline Fallback (if model exists locally, even if network failed)
                if hasLocalModel && (isTimeout || isMetadataError) {
                    print("[WhisperModelManager] Local model found. Retrying in OFFLINE mode...")
                    setenv("HF_HUB_OFFLINE", "1", 1)
                    
                    let offlineConfig = WhisperKitConfig(model: modelName)
                    offlineConfig.verbose = true
                    offlineConfig.logLevel = .debug
                    offlineConfig.downloadBase = paths.storage
                    
                    defer { unsetenv("HF_HUB_OFFLINE") }
                    newPipe = try await WhisperKit(offlineConfig)
                } 
                // Strategy 2: Cleanup and Retry (for corruption or persistent errors)
                else if retryCount > 0 {
                    if isTimeout {
                        print("[WhisperModelManager] Timeout detected. Retrying WITHOUT cleanup to allow resume...")
                        // Wait a bit before retrying to let network stabilize
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                    } else {
                        print("[WhisperModelManager] Suspected corruption (Metadata/Move error). Cleaning up and retrying...")
                        
                        // Delete the specific model repo directory
                        if FileManager.default.fileExists(atPath: repoPath.path) {
                            try? FileManager.default.removeItem(at: repoPath)
                            print("[WhisperModelManager] Deleted corrupted model directory: \(repoPath.path)")
                        }
                        
                        // If it's a metadata error, also clean up the global .cache/huggingface
                        if isMetadataError {
                            let globalCachePath = paths.storage.appendingPathComponent(".cache/huggingface")
                            if FileManager.default.fileExists(atPath: globalCachePath.path) {
                                try? FileManager.default.removeItem(at: globalCachePath)
                                print("[WhisperModelManager] Aggressively deleted global cache: \(globalCachePath.path)")
                            }
                        }
                    }
                    
                    // Recursive retry
                    try await loadModel(name, retryCount: retryCount - 1)
                    return
                } else {
                    throw error
                }
            }
            
            queue.async(flags: .barrier) {
                self.models[modelName] = .loaded(pipe: newPipe, inUseCount: 1)
            }
            
            await MainActor.run {
                self.isModelLoading = false
            }
            print("[WhisperModelManager] Model loaded successfully")
        } catch {
            print("[WhisperModelManager] Final failure to load model: \(error)")
            await MainActor.run {
                self.loadingError = error.localizedDescription
                self.isModelLoading = false
            }
            throw error
        }
    }
    
    func releaseModel(_ name: String) {
        queue.async(flags: .barrier) {
            guard let instance = self.models[name] else { return }
            
            if case .loaded(let p, let count) = instance {
                if count > 1 {
                    self.models[name] = .loaded(pipe: p, inUseCount: count - 1)
                } else {
                    self.models[name] = .cached(pipe: p, lastUsed: Date())
                }
            }
        }
    }
    
    func releaseCachedModels() {
        queue.async(flags: .barrier) {
            for (name, instance) in self.models {
                if case .cached = instance {
                    print("[WhisperModelManager] Releasing cached model: \(name)")
                    self.models[name] = .unloaded
                }
            }
        }
    }
    
    func cleanupExpiredModels() {
        let now = Date()
        queue.async(flags: .barrier) {
            for (name, instance) in self.models {
                if case .cached(_, let lastUsed) = instance {
                    if now.timeIntervalSince(lastUsed) > self.cacheTimeout {
                        print("[WhisperModelManager] Cleaning up expired model: \(name)")
                        self.models[name] = .unloaded
                    }
                }
            }
        }
    }
    
    func isModelLoaded(_ name: String) -> Bool {
        var isLoaded = false
        queue.sync {
            if let instance = models[name] {
                switch instance {
                case .loaded, .cached: isLoaded = true
                default: isLoaded = false
                }
            }
        }
        return isLoaded
    }
}
