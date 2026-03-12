import AppKit
import ApplicationServices
import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Foundation
import MusicKit
import Photos
import ScreenCaptureKit

extension AgentDaemon {
    func triggerPermissionPrompts() {
        logger.log("Triggering permission prompts...")

        logger.log("Requesting Accessibility permission...")
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        logger.log("Accessibility permission: \(accessibilityGranted ? "granted" : "not granted (dialog shown)")")

        if !accessibilityGranted {
            logger.log("Accessibility not yet granted, continuing with other permission requests...")
            Thread.sleep(forTimeInterval: 0.5)
        }

        logger.log("Requesting Screen Recording permission...")
        Task {
            do {
                let content = try await SCShareableContent.current
                if content.displays.isEmpty {
                    self.logger.log("Screen Recording: no displays (permission denied or pending)")
                } else {
                    self.logger.log("Screen Recording permission: granted (\(content.displays.count) displays)")
                }
            } catch {
                self.logger.log("Screen Recording permission request triggered: \(error)")
            }
        }

        triggerScreenshotPermissionProbe()

        triggerFileAccessPermissions()
        triggerPhotosAccessPermission()
        triggerContactsAccessPermission()
        triggerCalendarAccessPermission()
        triggerRemindersAccessPermission()
        triggerAppDataPermission()
        triggerAppBundlePermission()
        triggerMusicAuthorizationPermission()
        triggerRemovableVolumePermission()
        triggerNetworkVolumePermission()
        triggerFullDiskAccessCheck()
        triggerAutomationPermission()
        triggerCameraAndMicrophonePermissions()
        triggerLocationPermission()
        triggerBroaderDataAccessPermissions()
    }

    func triggerFileAccessPermissions() {
        logger.log("Requesting file access permissions for user folders...")
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedFolders = ["Desktop", "Documents", "Downloads"]

        for folderName in protectedFolders {
            let folderPath = (homeDirectory as NSString).appendingPathComponent(folderName)
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: folderPath)
                logger.log("\(folderName) folder access: granted (\(contents.count) items)")
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                    logger.log("\(folderName) folder access: permission dialog shown or denied")
                } else if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    logger.log("\(folderName) folder: does not exist")
                } else {
                    logger.log("\(folderName) folder access: \(error.localizedDescription)")
                }
            }
        }
    }

    func triggerBroaderDataAccessPermissions() {
        logger.log("Triggering broader data access permissions...")
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let additionalFolders: [(String, String)] = [
            ("Music", "Music folder"),
            ("Pictures", "Pictures folder"),
            ("Movies", "Movies folder")
        ]

        for (relativePath, description) in additionalFolders {
            let fullPath = (homeDirectory as NSString).appendingPathComponent(relativePath)
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: fullPath)
                logger.log("\(description): accessible (\(contents.count) items)")
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                    logger.log("\(description): permission dialog shown or denied")
                } else if error.code == NSFileNoSuchFileError {
                    logger.log("\(description): directory doesn't exist")
                } else {
                    logger.log("\(description): \(error.localizedDescription)")
                }
            }
        }

        do {
            let apps = try FileManager.default.contentsOfDirectory(atPath: "/Applications")
            logger.log("Applications directory: accessible (\(apps.count) apps)")
        } catch {
            logger.log("Applications directory: \(error.localizedDescription)")
        }

        let volumesPath = "/Volumes"
        if FileManager.default.fileExists(atPath: volumesPath) {
            do {
                let volumes = try FileManager.default.contentsOfDirectory(atPath: volumesPath)
                logger.log("Volumes: accessible (\(volumes.count) volumes)")
                for volume in volumes where volume != "Macintosh HD" {
                    let volumePath = (volumesPath as NSString).appendingPathComponent(volume)
                    _ = try? FileManager.default.contentsOfDirectory(atPath: volumePath)
                }
            } catch {
                logger.log("Volumes: \(error.localizedDescription)")
            }
        }
    }

    func triggerAppDataPermission() {
        logger.log("Requesting access to data from other apps...")

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let candidateRoots: [(String, String)] = [
            ("Library/Containers", "App containers"),
            ("Library/Application Support", "Application Support")
        ]

        for (relativePath, description) in candidateRoots {
            let rootPath = (homeDirectory as NSString).appendingPathComponent(relativePath)
            let rootURL = URL(fileURLWithPath: rootPath)

            do {
                let children = try FileManager.default.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )

                let directories = children
                    .filter { url in
                        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
                            return false
                        }
                        return values.isDirectory == true
                    }
                    .prefix(5)

                for candidateURL in directories {
                    do {
                        _ = try FileManager.default.contentsOfDirectory(
                            at: candidateURL,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        )
                        logger.log("App Data (\(description)): accessible via \(candidateURL.lastPathComponent)")
                        return
                    } catch let error as NSError {
                        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                            logger.log("App Data (\(description)): permission dialog shown or denied for \(candidateURL.lastPathComponent)")
                            return
                        }
                    }
                }
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                    logger.log("App Data (\(description)): permission dialog shown or denied")
                    return
                } else if error.code == NSFileNoSuchFileError {
                    logger.log("App Data (\(description)): directory doesn't exist")
                } else {
                    logger.log("App Data (\(description)): \(error.localizedDescription)")
                }
            }
        }

        logger.log("App Data access: no candidate app-data directories were available to probe")
    }

    func triggerMusicAuthorizationPermission() {
        logger.log("Requesting music and audio data access...")

        let status = MusicAuthorization.currentStatus
        switch status {
        case .authorized:
            logger.log("Music access: already authorized")
        case .notDetermined:
            Task {
                let newStatus = await MusicAuthorization.request()
                self.logger.log("Music access: \(newStatus.description)")
            }
        case .denied:
            logger.log("Music access: denied")
        case .restricted:
            logger.log("Music access: restricted")
        @unknown default:
            logger.log("Music access: unknown status")
        }
    }

    func triggerScreenshotPermissionProbe() {
        logger.log("Attempting a real screenshot as part of permission sweep...")

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            do {
                let result = try ScreenshotTool().executeSync()
                let width = result["width"] as? Int ?? 0
                let height = result["height"] as? Int ?? 0
                self.logger.log("Screenshot permission probe succeeded: \(width)x\(height)")
            } catch {
                self.logger.log("Screenshot permission probe failed: \(error.localizedDescription)")
            }
        }
    }

    func triggerAppBundlePermission() {
        logger.log("Requesting access to installed app bundles...")

        let applicationsURL = URL(fileURLWithPath: "/Applications")

        do {
            let applicationURLs = try FileManager.default.contentsOfDirectory(
                at: applicationsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            if let appBundleURL = applicationURLs.first(where: { $0.pathExtension == "app" }) {
                let contentsURL = appBundleURL.appendingPathComponent("Contents")
                _ = try FileManager.default.contentsOfDirectory(
                    at: contentsURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                logger.log("App Bundles: accessible via \(appBundleURL.lastPathComponent)")
            } else {
                logger.log("App Bundles: /Applications is accessible but no app bundles were found to probe")
            }
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                logger.log("App Bundles: permission dialog shown or denied")
            } else {
                logger.log("App Bundles: \(error.localizedDescription)")
            }
        }
    }

    func triggerRemovableVolumePermission() {
        logger.log("Requesting access to removable volumes...")

        let candidateVolume = mountedVolumeURLs().first { volumeURL in
            (try? volumeURL.resourceValues(forKeys: [.volumeIsRemovableKey]).volumeIsRemovable) == true
        }

        if let candidateVolume {
            probeVolume(candidateVolume, category: "Removable Volumes")
            return
        }

        let volumesURL = URL(fileURLWithPath: "/Volumes")
        do {
            let volumes = try FileManager.default.contentsOfDirectory(
                at: volumesURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            logger.log("Removable Volumes: no removable volumes mounted (\(volumes.count) total mounted volumes visible)")
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                logger.log("Removable Volumes: permission dialog shown or denied")
            } else {
                logger.log("Removable Volumes: \(error.localizedDescription)")
            }
        }
    }

    func triggerNetworkVolumePermission() {
        logger.log("Requesting access to network volumes...")

        let candidateVolume = mountedVolumeURLs().first { volumeURL in
            (try? volumeURL.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false
        }

        if let candidateVolume {
            probeVolume(candidateVolume, category: "Network Volumes")
            return
        }

        logger.log("Network Volumes: no mounted network volumes were available to probe")
    }

    private func mountedVolumeURLs() -> [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsRemovableKey, .volumeIsLocalKey],
            options: [.skipHiddenVolumes]
        ) ?? []
    }

    private func probeVolume(_ volumeURL: URL, category: String) {
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: volumeURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            logger.log("\(category): accessible via \(volumeURL.lastPathComponent)")
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                logger.log("\(category): permission dialog shown or denied for \(volumeURL.lastPathComponent)")
            } else {
                logger.log("\(category): \(error.localizedDescription)")
            }
        }
    }

    func triggerPhotosAccessPermission() {
        logger.log("Requesting Photos library access...")
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch status {
        case .authorized, .limited:
            logger.log("Photos access: already authorized")
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                switch newStatus {
                case .authorized:
                    self.logger.log("Photos access: authorized")
                case .limited:
                    self.logger.log("Photos access: limited access granted")
                case .denied, .restricted:
                    self.logger.log("Photos access: denied or restricted")
                case .notDetermined:
                    self.logger.log("Photos access: still not determined")
                @unknown default:
                    self.logger.log("Photos access: unknown status")
                }
            }
        case .denied, .restricted:
            logger.log("Photos access: previously denied or restricted")
        @unknown default:
            logger.log("Photos access: unknown status")
        }
    }

    func triggerContactsAccessPermission() {
        logger.log("Requesting Contacts access...")
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        switch status {
        case .authorized:
            logger.log("Contacts access: already authorized")
        case .notDetermined:
            store.requestAccess(for: .contacts) { granted, error in
                if granted {
                    self.logger.log("Contacts access: authorized")
                } else if let error = error {
                    self.logger.log("Contacts access: denied - \(error.localizedDescription)")
                } else {
                    self.logger.log("Contacts access: denied")
                }
            }
        case .denied, .restricted:
            logger.log("Contacts access: previously denied or restricted")
        case .limited:
            logger.log("Contacts access: limited access granted")
        @unknown default:
            logger.log("Contacts access: unknown status")
        }
    }

    func triggerCalendarAccessPermission() {
        logger.log("Requesting Calendar access...")
        let eventStore = EKEventStore()

        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .authorized, .fullAccess, .writeOnly:
                logger.log("Calendar access: already authorized")
            case .notDetermined:
                eventStore.requestFullAccessToEvents { granted, error in
                    if granted {
                        self.logger.log("Calendar access: authorized")
                    } else if let error = error {
                        self.logger.log("Calendar access: denied - \(error.localizedDescription)")
                    } else {
                        self.logger.log("Calendar access: denied")
                    }
                }
            case .denied, .restricted:
                logger.log("Calendar access: previously denied or restricted")
            @unknown default:
                logger.log("Calendar access: unknown status")
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                if granted {
                    self.logger.log("Calendar access: authorized")
                } else if let error = error {
                    self.logger.log("Calendar access: denied - \(error.localizedDescription)")
                } else {
                    self.logger.log("Calendar access: denied")
                }
            }
        }
    }

    func triggerRemindersAccessPermission() {
        logger.log("Requesting Reminders access...")
        let eventStore = EKEventStore()

        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            switch status {
            case .authorized, .fullAccess, .writeOnly:
                logger.log("Reminders access: already authorized")
            case .notDetermined:
                eventStore.requestFullAccessToReminders { granted, error in
                    if granted {
                        self.logger.log("Reminders access: authorized")
                    } else if let error = error {
                        self.logger.log("Reminders access: denied - \(error.localizedDescription)")
                    } else {
                        self.logger.log("Reminders access: denied")
                    }
                }
            case .denied, .restricted:
                logger.log("Reminders access: previously denied or restricted")
            @unknown default:
                logger.log("Reminders access: unknown status")
            }
        } else {
            eventStore.requestAccess(to: .reminder) { granted, error in
                if granted {
                    self.logger.log("Reminders access: authorized")
                } else if let error = error {
                    self.logger.log("Reminders access: denied - \(error.localizedDescription)")
                } else {
                    self.logger.log("Reminders access: denied")
                }
            }
        }
    }
}
