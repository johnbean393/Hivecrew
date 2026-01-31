//
//  OnboardingOutputDirectoryStep.swift
//  Hivecrew
//
//  Output directory setup step of the onboarding wizard
//

import SwiftUI
import UniformTypeIdentifiers

/// Output directory configuration step
struct OnboardingOutputDirectoryStep: View {
    @AppStorage("outputDirectoryPath") private var outputDirectoryPath: String = ""
    
    @State private var showingFolderPicker = false
    
    /// Default output directory (Downloads)
    private var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    }
    
    /// The configured output directory, or default if not set
    private var effectiveOutputDirectory: URL {
        if outputDirectoryPath.isEmpty {
            return defaultOutputDirectory
        }
        return URL(fileURLWithPath: outputDirectoryPath)
    }
    
    /// Display-friendly path
    private var displayPath: String {
        if outputDirectoryPath.isEmpty {
            return "~/Downloads"
        }
        return outputDirectoryPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Header
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                
                Text("Output Directory")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("When agents create deliverable files, they're automatically copied here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Example
            exampleCard
                .padding(.horizontal, 50)
            
            Spacer()
            
            // Directory selection
            VStack(spacing: 8) {
                HStack {
                    Text(displayPath)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Button("Choose...") {
                        showingFolderPicker = true
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                )
                
                HStack(spacing: 16) {
                    if outputDirectoryPath.isEmpty {
                        Text("Using default. You can skip this step.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Reset to Default") {
                            outputDirectoryPath = ""
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 50)
            
            Spacer()
        }
        .padding()
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                outputDirectoryPath = url.path
            }
        }
    }
    
    // MARK: - Subviews
    
    private var exampleCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("*\"Create a comparison of the top EVs\"*")
                    .font(.callout)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                    Text("Agent saves `EV_Comparison.xlsx` to this folder")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    OnboardingOutputDirectoryStep()
        .frame(width: 600, height: 550)
}
