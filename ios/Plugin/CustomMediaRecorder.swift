import Foundation
import AVFoundation
// replace acc to m4a
class CustomMediaRecorder {

    var options: RecordOptions!
    private var recordingSession: AVAudioSession!
    private var audioRecorder: AVAudioRecorder!
    private var baseAudioFilePath: URL!
    private var audioFileSegments: [URL] = []
    private var originalRecordingSessionCategory: AVAudioSession.Category!
    private var status = CurrentRecordingStatus.NONE
    private var interruptionObserver: NSObjectProtocol?
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?

    private let settings = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    private func getDirectoryToSaveAudioFile() -> URL {
        if let directory = getDirectory(directory: options.directory),
           var outputDirURL = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            if let subDirectory = options.subDirectory?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                options.setSubDirectory(to: subDirectory)
                outputDirURL = outputDirURL.appendingPathComponent(subDirectory, isDirectory: true)

                do {
                    if !FileManager.default.fileExists(atPath: outputDirURL.path) {
                        try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
                    }
                } catch {
                    print("Error creating directory: \(error)")
                }
            }

            return outputDirURL
        }

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    func startRecording(recordOptions: RecordOptions) -> Bool {
        do {
            options = recordOptions
            recordingSession = AVAudioSession.sharedInstance()
            originalRecordingSessionCategory = recordingSession.category
            try recordingSession.setCategory(AVAudioSession.Category.playAndRecord)
            try recordingSession.setActive(true)
            baseAudioFilePath = getDirectoryToSaveAudioFile().appendingPathComponent("recording-\(Int(Date().timeIntervalSince1970 * 1000)).m4a")

            // Initialize segment tracking
            audioFileSegments = [baseAudioFilePath]

            audioRecorder = try AVAudioRecorder(url: baseAudioFilePath, settings: settings)

            // Subscribe to interruption notifications
            setupInterruptionHandling()

            audioRecorder.record()
            status = CurrentRecordingStatus.RECORDING
            return true
        } catch {
            return false
        }
    }

    func stopRecording() -> Bool {
        do {
            // Remove interruption observer
            removeInterruptionHandling()

            audioRecorder.stop()

            // Merge segments if there were interruptions
            if audioFileSegments.count > 1 {
                if !mergeAudioSegments() {
                    // Merge failed - return false
                    return false
                }
            }

            try recordingSession.setActive(false)
            try recordingSession.setCategory(originalRecordingSessionCategory)
            originalRecordingSessionCategory = nil
            audioRecorder = nil
            recordingSession = nil
            status = CurrentRecordingStatus.NONE
            return true
        } catch {
            return false
        }
    }

    func getOutputFile() -> URL {
        return baseAudioFilePath
    }

    func getDirectory(directory: String?) -> FileManager.SearchPathDirectory? {
        if let directory = directory {
            switch directory {
            case "CACHE":
                return .cachesDirectory
            case "LIBRARY":
                return .libraryDirectory
            default:
                return .documentDirectory
            }
        }
        return nil
    }

    func pauseRecording() -> Bool {
        if status == CurrentRecordingStatus.RECORDING {
            audioRecorder.pause()
            status = CurrentRecordingStatus.PAUSED
            return true
        } else {
            return false
        }
    }

    func resumeRecording() -> Bool {
        if status == CurrentRecordingStatus.PAUSED || status == CurrentRecordingStatus.INTERRUPTED {
            do {
                // Ensure audio session is active before resuming
                try recordingSession.setActive(true)

                // If resuming from interruption, create a new segment
                if status == CurrentRecordingStatus.INTERRUPTED {
                    // Create new segment file
                    let directory = getDirectoryToSaveAudioFile()
                    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                    let segmentNumber = audioFileSegments.count
                    let segmentPath = directory.appendingPathComponent("recording-\(timestamp)-segment-\(segmentNumber).m4a")

                    // Initialize new recorder with segment file
                    audioRecorder = try AVAudioRecorder(url: segmentPath, settings: settings)
                    audioFileSegments.append(segmentPath)
                }

                audioRecorder.record()
                status = CurrentRecordingStatus.RECORDING
                return true
            } catch {
                return false
            }
        } else {
            return false
        }
    }

    func getCurrentStatus() -> CurrentRecordingStatus {
        return status
    }

    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification: notification)
        }
    }

    private func removeInterruptionHandling() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }

    private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let interruptionTypeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let interruptionType = AVAudioSession.InterruptionType(rawValue: interruptionTypeValue) else {
            return
        }

        switch interruptionType {
        case .began:
            // Interruption began (e.g., phone call incoming)
            if status == CurrentRecordingStatus.RECORDING {
                audioRecorder.stop()
                status = CurrentRecordingStatus.INTERRUPTED
                onInterruptionBegan?()
            }

        case .ended:
            // Interruption ended, but keep state as INTERRUPTED
            // Let the user decide whether to resume or stop
            if status == CurrentRecordingStatus.INTERRUPTED {
                onInterruptionEnded?()
            }

        @unknown default:
            break
        }
    }

    private func mergeAudioSegments() -> Bool {
        // If only one segment, no merge needed
        if audioFileSegments.count <= 1 {
            return true
        }

        print("[VoiceRecorder] Starting merge of \(audioFileSegments.count) segments")

        // Update base path extension to .m4a since we're exporting to M4A format
        let basePathWithoutExtension = baseAudioFilePath.deletingPathExtension()
        baseAudioFilePath = basePathWithoutExtension.appendingPathExtension("m4a")

        // Create composition
        let composition = AVMutableComposition()
        guard let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            print("[VoiceRecorder] Failed to create composition audio track")
            return false
        }

        var insertTime = CMTime.zero

        // Add each segment to the composition
        for (index, segmentURL) in audioFileSegments.enumerated() {
            let asset = AVURLAsset(url: segmentURL)

            // Wait for asset to load
            let keys = ["tracks", "duration"]
            asset.loadValuesAsynchronously(forKeys: keys) {}

            // Check if tracks are available
            guard let assetTrack = asset.tracks(withMediaType: .audio).first else {
                print("[VoiceRecorder] Segment \(index) at \(segmentURL.lastPathComponent) has no audio track")
                return false
            }

            let duration = asset.duration
            let durationSeconds = CMTimeGetSeconds(duration)
            print("[VoiceRecorder] Segment \(index): \(segmentURL.lastPathComponent), duration: \(durationSeconds)s")

            do {
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                try compositionAudioTrack.insertTimeRange(timeRange, of: assetTrack, at: insertTime)
                insertTime = CMTimeAdd(insertTime, duration)
            } catch {
                print("[VoiceRecorder] Failed to insert segment \(index): \(error.localizedDescription)")
                return false
            }
        }

        let totalDuration = CMTimeGetSeconds(insertTime)
        print("[VoiceRecorder] Total composition duration: \(totalDuration)s")

        // Export the composition
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            print("[VoiceRecorder] Failed to create export session")
            return false
        }

        // Create temporary export path (will be moved to baseAudioFilePath)
        let tempDirectory = getDirectoryToSaveAudioFile()
        let tempPath = tempDirectory.appendingPathComponent("temp-merged-\(Int(Date().timeIntervalSince1970 * 1000)).m4a")

        exportSession.outputURL = tempPath
        exportSession.outputFileType = .m4a

        print("[VoiceRecorder] Exporting to temp path: \(tempPath.lastPathComponent)")

        // Use a semaphore for synchronous export
        let semaphore = DispatchSemaphore(value: 0)

        exportSession.exportAsynchronously {
            semaphore.signal()
        }

        semaphore.wait()

        // Check export status
        switch exportSession.status {
        case .completed:
            print("[VoiceRecorder] Export completed successfully")

            // Verify exported file exists and has content
            if FileManager.default.fileExists(atPath: tempPath.path) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: tempPath.path)
                    let fileSize = attributes[.size] as? Int64 ?? 0
                    print("[VoiceRecorder] Exported file size: \(fileSize) bytes")

                    // Check duration of exported file
                    let exportedAsset = AVURLAsset(url: tempPath)
                    let exportedDuration = CMTimeGetSeconds(exportedAsset.duration)
                    print("[VoiceRecorder] Exported file duration: \(exportedDuration)s")
                } catch {
                    print("[VoiceRecorder] Error checking exported file: \(error.localizedDescription)")
                }
            } else {
                print("[VoiceRecorder] ERROR: Exported file does not exist at temp path!")
                return false
            }

            // Move merged file to base path
            do {
                // Remove base file if it exists
                if FileManager.default.fileExists(atPath: baseAudioFilePath.path) {
                    print("[VoiceRecorder] Removing existing file at base path")
                    try FileManager.default.removeItem(at: baseAudioFilePath)
                }

                // Move temp file to base path
                print("[VoiceRecorder] Moving merged file to: \(baseAudioFilePath.lastPathComponent)")
                try FileManager.default.moveItem(at: tempPath, to: baseAudioFilePath)

                // Clean up segment files
                print("[VoiceRecorder] Cleaning up \(audioFileSegments.count) segment files")
                for segmentURL in audioFileSegments {
                    if segmentURL != baseAudioFilePath && FileManager.default.fileExists(atPath: segmentURL.path) {
                        try? FileManager.default.removeItem(at: segmentURL)
                        print("[VoiceRecorder] Deleted segment: \(segmentURL.lastPathComponent)")
                    }
                }

                print("[VoiceRecorder] Merge completed successfully")
                return true
            } catch {
                print("[VoiceRecorder] Failed to move/cleanup files: \(error.localizedDescription)")
                return false
            }

        case .failed:
            print("[VoiceRecorder] Export FAILED: \(exportSession.error?.localizedDescription ?? "unknown error")")
            return false

        case .cancelled:
            print("[VoiceRecorder] Export was cancelled")
            return false

        default:
            print("[VoiceRecorder] Export ended with unexpected status: \(exportSession.status.rawValue)")
            return false
        }
    }

}
