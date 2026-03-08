import AppKit
import AVFoundation
import CoreLocation
import Foundation

extension AgentDaemon {
    func triggerFullDiskAccessCheck() {
        logger.log("Checking Full Disk Access...")
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedDirectories = [
            ("Library/Mail", "Mail data"),
            ("Library/Messages", "Messages data"),
            ("Library/Safari", "Safari data"),
            ("Library/Cookies", "Cookies"),
            ("Library/Application Support/MobileSync", "iOS backups")
        ]

        var hasFullDiskAccess = true
        for (relativePath, description) in protectedDirectories {
            let fullPath = (homeDirectory as NSString).appendingPathComponent(relativePath)
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: fullPath)
                logger.log("Full Disk Access (\(description)): accessible")
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                    hasFullDiskAccess = false
                    logger.log("Full Disk Access (\(description)): not accessible - permission denied")
                } else if error.code == NSFileNoSuchFileError {
                    logger.log("Full Disk Access (\(description)): directory doesn't exist")
                } else {
                    logger.log("Full Disk Access (\(description)): \(error.localizedDescription)")
                }
            }
        }

        if !hasFullDiskAccess {
            logger.log("Full Disk Access: Not fully granted. Some protected directories are inaccessible.")
            logger.log("To grant Full Disk Access: System Settings > Privacy & Security > Full Disk Access")
        } else {
            logger.log("Full Disk Access: All tested directories accessible")
        }
    }

    func triggerAutomationPermission() {
        logger.log("Checking Automation permissions...")

        let script = """
        tell application "System Events"
            return name of first process whose frontmost is true
        end tell
        """

        DispatchQueue.global(qos: .utility).async {
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)

                if let error = error {
                    let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? 0
                    if errorNumber == -1743 {
                        self.logger.log("Automation (System Events): permission prompt shown or denied")
                    } else {
                        self.logger.log("Automation (System Events): error \(errorNumber)")
                    }
                } else {
                    self.logger.log("Automation (System Events): authorized - \(result.stringValue ?? "success")")
                }
            } else {
                self.logger.log("Automation: failed to create AppleScript")
            }
        }

        let finderScript = """
        tell application "Finder"
            return name of desktop
        end tell
        """

        DispatchQueue.global(qos: .utility).async {
            if let appleScript = NSAppleScript(source: finderScript) {
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)

                if let error = error {
                    let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? 0
                    if errorNumber == -1743 {
                        self.logger.log("Automation (Finder): permission prompt shown or denied")
                    } else {
                        self.logger.log("Automation (Finder): error \(errorNumber)")
                    }
                } else {
                    self.logger.log("Automation (Finder): authorized - \(result.stringValue ?? "success")")
                }
            }
        }
    }

    func triggerCameraAndMicrophonePermissions() {
        logger.log("Requesting Camera and Microphone access...")

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraStatus {
        case .authorized:
            logger.log("Camera access: already authorized")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.logger.log("Camera access: \(granted ? "authorized" : "denied")")
            }
        case .denied, .restricted:
            logger.log("Camera access: previously denied or restricted")
        @unknown default:
            logger.log("Camera access: unknown status")
        }

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch microphoneStatus {
        case .authorized:
            logger.log("Microphone access: already authorized")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                self.logger.log("Microphone access: \(granted ? "authorized" : "denied")")
            }
        case .denied, .restricted:
            logger.log("Microphone access: previously denied or restricted")
        @unknown default:
            logger.log("Microphone access: unknown status")
        }
    }

    func triggerLocationPermission() {
        logger.log("Checking Location Services access...")
        let status = CLLocationManager.authorizationStatus()

        switch status {
        case .authorizedAlways:
            logger.log("Location access: authorized always")
        case .authorized:
            logger.log("Location access: authorized")
        case .notDetermined:
            logger.log("Location access: not determined (requires user action in System Settings)")
            logger.log("To enable Location Services: System Settings > Privacy & Security > Location Services")
        case .denied:
            logger.log("Location access: denied")
        case .restricted:
            logger.log("Location access: restricted")
        @unknown default:
            logger.log("Location access: unknown status")
        }

        if !CLLocationManager.locationServicesEnabled() {
            logger.log("Location Services: disabled system-wide")
        }
    }

    func mountSharedFolder() {
        let sharedPath = "/Volumes/Shared"
        if FileManager.default.fileExists(atPath: sharedPath) {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: sharedPath)
            if let contents = contents, !contents.isEmpty {
                logger.log("Shared folder already mounted at \(sharedPath)")
                return
            }
        }

        logger.log("Attempting to mount shared folder...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            if [ ! -d "\(sharedPath)" ]; then
                mkdir -p "\(sharedPath)" 2>/dev/null
            fi

            mount_virtiofs shared "\(sharedPath)" 2>/dev/null || \
            echo "Mount failed - may need manual setup"
            """]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let mountTimeout: TimeInterval = 10

        do {
            try process.run()
            let deadline = Date(timeIntervalSinceNow: mountTimeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
            }

            if process.isRunning {
                logger.warning("Mount process timed out after \(Int(mountTimeout))s - terminating")
                process.terminate()
                Thread.sleep(forTimeInterval: 1.0)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return
            }

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                logger.log("Mount output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            if FileManager.default.fileExists(atPath: sharedPath) {
                let contents = try? FileManager.default.contentsOfDirectory(atPath: sharedPath)
                if let contents = contents, !contents.isEmpty {
                    logger.log("Shared folder mounted successfully")
                } else {
                    logger.log("Shared folder mount point exists but appears empty")
                }
            }
        } catch {
            logger.log("Failed to run mount command: \(error)")
        }
    }
}
