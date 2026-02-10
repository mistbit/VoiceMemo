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
    }
    
    func loadModel(_ name: String) async throws {
        let modelName: String
        if !name.contains("openai_whisper-") {
            modelName = "openai_whisper-\(name)"
        } else {
            modelName = name
        }
        
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
            print("[WhisperModelManager] Loading model: \(modelName)")
            
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
            
            // Set explicit download base to ensure persistence across runs
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let modelStoragePath = appSupport.appendingPathComponent("VoiceMemo/Models")
            
            // Create directory if not exists
            try? FileManager.default.createDirectory(at: modelStoragePath, withIntermediateDirectories: true)
            
            config.downloadBase = modelStoragePath
            print("[WhisperModelManager] Final Download Base: \(modelStoragePath.path)")
            print("[WhisperModelManager] Model Repo: \(config.modelRepo ?? "argmaxinc/whisperkit-coreml")")
            
            // Try to initialize WhisperKit
            let newPipe: WhisperKit
            do {
                newPipe = try await WhisperKit(config)
            } catch {
                // If initialization fails (e.g. timeout) and we suspect we have the model locally, try offline mode
                print("[WhisperModelManager] Initial load failed: \(error). Checking for local cache...")
                
                // Check if we can find the model in the cache
                // Structure: <base>/models--<org>--<repo>/snapshots/<hash>
                let repoName = config.modelRepo ?? "argmaxinc/whisperkit-coreml"
                let repoDirName = "models--" + repoName.replacingOccurrences(of: "/", with: "--")
                let repoPath = modelStoragePath.appendingPathComponent(repoDirName)
                
                let snapshotsPath = repoPath.appendingPathComponent("snapshots")
                
                var hasLocalModel = false
                if let snapshotContents = try? FileManager.default.contentsOfDirectory(at: snapshotsPath, includingPropertiesForKeys: nil),
                   !snapshotContents.isEmpty {
                    print("[WhisperModelManager] Found local snapshots: \(snapshotContents.map { $0.lastPathComponent })")
                    hasLocalModel = true
                }
                
                if hasLocalModel {
                    print("[WhisperModelManager] Local model found. Retrying in OFFLINE mode...")
                    setenv("HF_HUB_OFFLINE", "1", 1)
                    // Re-create config because WhisperKit might have modified it or we want clean state
                    let offlineConfig = WhisperKitConfig(model: modelName)
                    offlineConfig.verbose = true
                    offlineConfig.logLevel = .debug
                    offlineConfig.downloadBase = modelStoragePath
                    
                    newPipe = try await WhisperKit(offlineConfig)
                    
                    // Reset OFFLINE mode for future requests
                    unsetenv("HF_HUB_OFFLINE")
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
            print("[WhisperModelManager] Failed to load model: \(error)")
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
