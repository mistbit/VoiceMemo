import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case recording
    case importAudio
    case history
    case settings

    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .recording: return "Recording"
        case .importAudio: return "Import"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }
    
    var icon: String {
        switch self {
        case .recording: return "mic"
        case .importAudio: return "square.and.arrow.down"
        case .history: return "clock"
        case .settings: return "gear"
        }
    }
}

enum RecordingModeItem: String, Hashable, CaseIterable, Identifiable {
    case mixed
    case remoteOnly
    case localOnly
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .mixed: return "Mixed Mode"
        case .remoteOnly: return "Remote Only"
        case .localOnly: return "Local Only"
        }
    }
    
    var description: String {
        switch self {
        case .mixed: return "Merges system and microphone audio automatically."
        case .remoteOnly: return "Records system audio only."
        case .localOnly: return "Records microphone only."
        }
    }
    
    var icon: String {
        switch self {
        case .mixed: return "arrow.triangle.merge"
        case .remoteOnly: return "speaker.wave.2"
        case .localOnly: return "mic"
        }
    }
}

enum ImportModeItem: String, Hashable, CaseIterable, Identifiable {
    case file
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .file: return "From File"
        }
    }
    
    var description: String {
        switch self {
        case .file: return "Import local audio files to create tasks."
        }
    }
    
    var icon: String {
        switch self {
        case .file: return "doc.badge.plus"
        }
    }
}

enum SettingsCategory: String, Hashable, CaseIterable, Identifiable {
    case general
    case asr
    case oss
    case storage
    case logs
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .general: return "General"
        case .asr: return "ASR Service"
        case .oss: return "Object Storage"
        case .storage: return "Storage"
        case .logs: return "Logs"
        }
    }
    
    var description: String {
        switch self {
        case .general: return "Basic settings including language and appearance."
        case .asr: return "Configure Speech-to-Text providers and parameters."
        case .oss: return "Configure Object Storage Service (OSS) settings."
        case .storage: return "Manage data persistence and database connections."
        case .logs: return "View and manage application logs."
        }
    }
    
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .asr: return "waveform"
        case .oss: return "server.rack"
        case .storage: return "externaldrive"
        case .logs: return "doc.text"
        }
    }
}
