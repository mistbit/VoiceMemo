import SwiftUI

struct LocalInferenceSettingsView: View {
    @ObservedObject var modelManager = WhisperModelManager.shared
    @ObservedObject var settings: SettingsStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Whisper Models")
                .font(.headline)
            
            Text("Models are downloaded automatically when selected. Larger models are more accurate but slower.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Toggle("Use HF Mirror (hf-mirror.com)", isOn: $settings.useHFMirror)
                .toggleStyle(.checkbox)
            Text("Enable if you have trouble downloading models from Hugging Face.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ForEach(modelManager.availableModels, id: \.self) { modelName in
                let isDownloaded = modelManager.downloadedModels.contains(modelName)
                let isDownloading = modelManager.isDownloading && modelManager.currentModelName.contains(modelName)
                let isSelected = settings.whisperModel == modelName
                
                HStack {
                    VStack(alignment: .leading) {
                        Text(modelName)
                            .fontWeight(isSelected ? .bold : .regular)
                        if isDownloaded {
                            Text("Downloaded")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                    
                    Spacer()
                    
                    if isDownloading {
                        VStack(alignment: .trailing) {
                            ProgressView(value: modelManager.downloadProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 100)
                            Text("\(Int(modelManager.downloadProgress * 100))%")
                                .font(.caption2)
                        }
                    } else {
                        HStack(spacing: 12) {
                            if !isDownloaded {
                                Button("Download") {
                                    Task {
                                        try? await modelManager.downloadModel(modelName)
                                    }
                                }
                            }
                            
                            if isSelected {
                                if modelManager.isModelLoading {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                    Text("Loading...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Active")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Button("Select") {
                                    settings.whisperModel = modelName
                                    Task {
                                        try? await modelManager.loadModel(modelName)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
            
            if let error = modelManager.loadingError {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
                Spacer()
                Button(action: {
                    modelManager.deleteModel()
                }) {
                    Text("Clear All Local Models")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.top, 4)
            
            Divider()
            
            Text("Debug Tools")
                .font(.headline)
            
            Toggle("Save Intermediate Audio", isOn: $settings.debugSaveIntermediateAudio)
                .toggleStyle(.checkbox)
            Text("Saves preprocessed audio (16kHz mono) to temporary folder")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Toggle("Export Raw Results", isOn: $settings.debugExportRawResults)
                .toggleStyle(.checkbox)
            Text("Saves raw JSON from WhisperKit and FluidAudio before fusion")
                .font(.caption)
                .foregroundColor(.secondary)
                
            Toggle("Log Model Inference Time", isOn: $settings.debugLogModelTime)
                .toggleStyle(.checkbox)
            
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
