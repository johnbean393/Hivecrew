//
//  TemplateDownloadService+UpdateChecking.swift
//  Hivecrew
//
//  Update checking functionality for TemplateDownloadService
//

import Foundation
import HivecrewShared

// MARK: - Update Checking

extension TemplateDownloadService {
    
    /// Check for template updates from the remote manifest
    /// - Parameter force: If true, check even if we recently checked
    /// - Returns: The available update template, if any
    @discardableResult
    func checkForUpdatesFromManifest(force: Bool = false) async -> RemoteTemplate? {
        // Don't check too frequently unless forced
        if !force, let lastCheck = lastUpdateCheck, Date().timeIntervalSince(lastCheck) < 3600 {
            if let update = availableUpdate {
                let currentVersion = getCurrentInstalledVersion() ?? "0.0.0"
                logUpdateCheckDiagnostics(
                    reason: "cached",
                    newestVersion: update.version,
                    currentVersion: currentVersion,
                    installedVersions: collectInstalledVersionCandidates(),
                    storedVersion: lastKnownCompatibleVersion,
                    availableUpdateVersion: availableUpdate?.version,
                    lastCheck: lastUpdateCheck,
                    force: force
                )
                if compareSemanticVersions(update.version, currentVersion) == .orderedDescending {
                    return update
                }
                updateAvailable = false
                availableUpdate = nil
            }
            return availableUpdate
        }
        
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        
        do {
            let manifest = try await fetchManifestFromRemote()
            lastUpdateCheck = Date()
            UserDefaults.standard.set(lastUpdateCheck, forKey: "lastTemplateUpdateCheckDate")
            
            // Find compatible templates
            let compatibleTemplates = manifest.templates.filter { template in
                isTemplateCompatibleWithApp(template)
            }
            
            // Sort by version (newest first)
            let sorted = compatibleTemplates.sorted { t1, t2 in
                compareSemanticVersions(t1.version, t2.version) == .orderedDescending
            }
            
            guard let newest = sorted.first,
                  let remoteTemplate = newest.toRemoteTemplate() else {
                updateAvailable = false
                availableUpdate = nil
                return nil
            }
            
            // Check if this is newer than what we have
            let currentVersion = getCurrentInstalledVersion() ?? "0.0.0"
            logUpdateCheckDiagnostics(
                reason: "manifest",
                newestVersion: newest.version,
                currentVersion: currentVersion,
                installedVersions: collectInstalledVersionCandidates(),
                storedVersion: lastKnownCompatibleVersion,
                availableUpdateVersion: availableUpdate?.version,
                lastCheck: lastUpdateCheck,
                force: force
            )
            if compareSemanticVersions(newest.version, currentVersion) == .orderedDescending {
                updateAvailable = true
                availableUpdate = remoteTemplate
                return remoteTemplate
            }
            
            updateAvailable = false
            availableUpdate = nil
            return nil
            
        } catch {
            print("Failed to check for template updates: \(error)")
            return nil
        }
    }
    
    /// Fetch the remote manifest
    func fetchManifestFromRemote() async throws -> TemplateManifest {
        let manifestURL = URL(string: "https://templates.hivecrew.org/manifest.json")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(from: manifestURL)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TemplateDownloadError.downloadFailed("Failed to fetch manifest")
        }
        
        let manifest = try JSONDecoder().decode(TemplateManifest.self, from: data)
        
        // Cache the manifest
        UserDefaults.standard.set(data, forKey: "cachedTemplateManifest")
        
        return manifest
    }
    
    /// Check if a template is compatible with the current app version
    func isTemplateCompatibleWithApp(_ template: TemplateManifest.ManifestTemplate) -> Bool {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        
        // Check minimum app version
        if let minVersion = template.minimumAppVersion {
            if compareSemanticVersions(appVersion, minVersion) == .orderedAscending {
                return false // App is too old
            }
        }
        
        // Check maximum app version
        if let maxVersion = template.maximumAppVersion {
            if compareSemanticVersions(appVersion, maxVersion) == .orderedDescending {
                return false // App is too new
            }
        }
        
        return true
    }
    
    /// Compare semantic version strings
    func compareSemanticVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let components1 = v1.split(separator: ".").compactMap { Int($0) }
        let components2 = v2.split(separator: ".").compactMap { Int($0) }
        
        let maxLength = max(components1.count, components2.count)
        
        for i in 0..<maxLength {
            let c1 = i < components1.count ? components1[i] : 0
            let c2 = i < components2.count ? components2[i] : 0
            
            if c1 < c2 { return .orderedAscending }
            if c1 > c2 { return .orderedDescending }
        }
        
        return .orderedSame
    }
    
    /// Get the current installed version by inspecting installed templates,
    /// falling back to stored UserDefaults if needed
    private func getCurrentInstalledVersion() -> String? {
        let versions = collectInstalledVersionCandidates()
        
        // Return the highest version found
        let sorted = versions.sorted { v1, v2 in
            compareSemanticVersions(v1, v2) == .orderedDescending
        }
        
        if let highestVersion = sorted.first {
            // Update UserDefaults so we don't need to scan again
            lastKnownCompatibleVersion = highestVersion
            return highestVersion
        }
        
        return lastKnownCompatibleVersion
    }
    
    private func collectInstalledVersionCandidates() -> [String] {
        let templatesDir = AppPaths.templatesDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: templatesDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        
        return contents.compactMap { url -> String? in
            guard url.hasDirectoryPath else { return nil }
            let configPath = url.appendingPathComponent("config.json")
            let config: [String: Any]? = {
                guard let data = try? Data(contentsOf: configPath),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return parsed
            }()
            
            if let version = config?["version"] as? String,
               let normalized = normalizeVersionString(version) {
                return normalized
            }
            
            if let configId = config?["id"] as? String,
               let normalized = normalizeVersionString(configId) {
                return normalized
            }
            
            if let configName = config?["name"] as? String,
               let normalized = normalizeVersionString(configName) {
                return normalized
            }
            
            return normalizeVersionString(url.lastPathComponent)
        }
    }
    
    /// Normalize a version string by extracting semantic version digits.
    private func normalizeVersionString(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Raw string: \d and \. are literal regex escapes (no double-escaping needed)
        let pattern = #"(\d+\.\d+\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let versionRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return String(trimmed[versionRange])
    }
    
    private func logUpdateCheckDiagnostics(
        reason: String,
        newestVersion: String?,
        currentVersion: String,
        installedVersions: [String],
        storedVersion: String?,
        availableUpdateVersion: String?,
        lastCheck: Date?,
        force: Bool
    ) {
        #if DEBUG
        let installedList = installedVersions.isEmpty ? "none" : installedVersions.joined(separator: ", ")
        print(
            """
            [TemplateUpdateCheck] reason=\(reason) force=\(force) lastCheck=\(lastCheck?.description ?? "nil")
            [TemplateUpdateCheck] newest=\(newestVersion ?? "nil") current=\(currentVersion) stored=\(storedVersion ?? "nil")
            [TemplateUpdateCheck] availableUpdate=\(availableUpdateVersion ?? "nil") installed=[\(installedList)]
            """
        )
        #endif
    }
}
