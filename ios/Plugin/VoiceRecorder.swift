import Foundation
import AVFoundation
import Capacitor

@objc(VoiceRecorder)
public class VoiceRecorder: CAPPlugin {
    
    // --- 核心新增：定时器 for 输出音量 ---
    private var meteringTimer: Timer?

    private var customMediaRecorder: CustomMediaRecorder?

    @objc func canDeviceVoiceRecord(_ call: CAPPluginCall) {
        call.resolve(ResponseGenerator.successResponse())
    }

    @objc func requestAudioRecordingPermission(_ call: CAPPluginCall) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            if granted {
                call.resolve(ResponseGenerator.successResponse())
            } else {
                call.resolve(ResponseGenerator.failResponse())
            }
        }
    }

    @objc func hasAudioRecordingPermission(_ call: CAPPluginCall) {
        call.resolve(ResponseGenerator.fromBoolean(doesUserGaveAudioRecordingPermission()))
    }

    @objc func startRecording(_ call: CAPPluginCall) {
        if !doesUserGaveAudioRecordingPermission() {
            call.reject(Messages.MISSING_PERMISSION)
            return
        }

        if customMediaRecorder != nil {
            call.reject(Messages.ALREADY_RECORDING)
            return
        }

        customMediaRecorder = CustomMediaRecorder()
        if customMediaRecorder == nil {
            call.reject(Messages.CANNOT_RECORD_ON_THIS_PHONE)
            return
        }

        // Set up interruption callbacks
        customMediaRecorder?.onInterruptionBegan = { [weak self] in
            self?.notifyListeners("voiceRecordingInterrupted", data: [:])
        }

        customMediaRecorder?.onInterruptionEnded = { [weak self] in
            self?.notifyListeners("voiceRecordingInterruptionEnded", data: [:])
        }

        let directory: String? = call.getString("directory")
        let subDirectory: String? = call.getString("subDirectory")
        let recordOptions = RecordOptions(directory: directory, subDirectory: subDirectory)
        let successfullyStartedRecording = customMediaRecorder!.startRecording(recordOptions: recordOptions)
        if successfullyStartedRecording == false {
            customMediaRecorder = nil
            call.reject(Messages.CANNOT_RECORD_ON_THIS_PHONE)
        } else {
            // --- 核心新增：开启仪表并启动定时器 ---
            // 1. 获取 recorder 实例并开启仪表监测
            if let recorder = self.customMediaRecorder?.getAudioRecorder() {
                recorder.isMeteringEnabled = true
                
                // 2. 启动定时器
                DispatchQueue.main.async {
                    self.meteringTimer?.invalidate() // 安全起见，先销毁旧的
                    self.meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                        guard let self = self,
                              let activeRecorder = self.customMediaRecorder?.getAudioRecorder(),
                              activeRecorder.isRecording else { return }
                        
                        activeRecorder.updateMeters()
                        let power = activeRecorder.averagePower(forChannel: 0)
                        
                        // 转换：-60dB (静音) 到 0dB (最大) 映射到 0.0 到 1.0
                        let minDb: Float = -60.0
                        var level: Float = 0.0
                        if power > minDb {
                            level = (power - minDb) / (0.0 - minDb)
                        }

                        // 通知前端
                        self.notifyListeners("onVolumeChange", data: ["value": level])
                    }
                }
            }
            // --- 新增结束 ---
            call.resolve(ResponseGenerator.successResponse())
        }
    }

    @objc func stopRecording(_ call: CAPPluginCall) {
        if customMediaRecorder == nil {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED)
            return
        }

        let stopSuccess = customMediaRecorder?.stopRecording() ?? false
        
        // --- 核心新增：停止录音时关闭定时器 ---
        self.meteringTimer?.invalidate()
        self.meteringTimer = nil
        // --- 新增结束 ---
        
        if !stopSuccess {
            customMediaRecorder = nil
            call.reject(Messages.FAILED_TO_MERGE_RECORDING)
            return
        }

        let audioFileUrl = customMediaRecorder?.getOutputFile()
        if audioFileUrl == nil {
            customMediaRecorder = nil
            call.reject(Messages.FAILED_TO_FETCH_RECORDING)
            return
        }

        var path = audioFileUrl!.lastPathComponent
        if let subDirectory = customMediaRecorder?.options?.subDirectory {
            path = subDirectory + "/" + path
        }

        // Determine MIME type based on file extension
        let fileExtension = audioFileUrl!.pathExtension.lowercased()
        let mimeType = fileExtension == "m4a" ? "audio/mp4" : "audio/aac"

        let sendDataAsBase64 = customMediaRecorder?.options?.directory == nil
        let recordData = RecordData(
            recordDataBase64: sendDataAsBase64 ? readFileAsBase64(audioFileUrl) : nil,
            mimeType: mimeType,
            msDuration: getMsDurationOfAudioFile(audioFileUrl),
            path: sendDataAsBase64 ? nil : path
        )
        customMediaRecorder = nil
        if (sendDataAsBase64 && recordData.recordDataBase64 == nil) || recordData.msDuration < 0 {
            call.reject(Messages.EMPTY_RECORDING)
        } else {
            call.resolve(ResponseGenerator.dataResponse(recordData.toDictionary()))
        }
    }

    @objc func pauseRecording(_ call: CAPPluginCall) {
        if customMediaRecorder == nil {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED)
        } else {
            call.resolve(ResponseGenerator.fromBoolean(customMediaRecorder?.pauseRecording() ?? false))
        }
    }

    @objc func resumeRecording(_ call: CAPPluginCall) {
        if customMediaRecorder == nil {
            call.reject(Messages.RECORDING_HAS_NOT_STARTED)
        } else {
            call.resolve(ResponseGenerator.fromBoolean(customMediaRecorder?.resumeRecording() ?? false))
        }
    }

    @objc func getCurrentStatus(_ call: CAPPluginCall) {
        if customMediaRecorder == nil {
            call.resolve(ResponseGenerator.statusResponse(CurrentRecordingStatus.NONE))
        } else {
            call.resolve(ResponseGenerator.statusResponse(customMediaRecorder?.getCurrentStatus() ?? CurrentRecordingStatus.NONE))
        }
    }

    func doesUserGaveAudioRecordingPermission() -> Bool {
        return AVAudioSession.sharedInstance().recordPermission == AVAudioSession.RecordPermission.granted
    }

    func readFileAsBase64(_ filePath: URL?) -> String? {
        if filePath == nil {
            return nil
        }

        do {
            let fileData = try Data.init(contentsOf: filePath!)
            let fileStream = fileData.base64EncodedString(options: NSData.Base64EncodingOptions.init(rawValue: 0))
            return fileStream
        } catch {}

        return nil
    }

    func getMsDurationOfAudioFile(_ filePath: URL?) -> Int {
        if filePath == nil {
            return -1
        }
        return Int(CMTimeGetSeconds(AVURLAsset(url: filePath!).duration) * 1000)
    }

}
