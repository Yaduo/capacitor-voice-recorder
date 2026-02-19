import type { Directory } from '@capacitor/filesystem';
import type { PluginListenerHandle } from '@capacitor/core';

export type Base64String = string;

export interface RecordingData {
  value: {
    recordDataBase64?: Base64String;
    msDuration: number;
    mimeType: string;
    path?: string;
  };
}

export type RecordingOptions =
  | never
  | {
      directory: Directory;
      subDirectory?: string;
    };

export interface GenericResponse {
  value: boolean;
}

export const RecordingStatus = {
  RECORDING: 'RECORDING',
  PAUSED: 'PAUSED',
  INTERRUPTED: 'INTERRUPTED',
  NONE: 'NONE',
} as const;

export interface CurrentRecordingStatus {
  status: (typeof RecordingStatus)[keyof typeof RecordingStatus];
}

/**
 * Event payload for voiceRecordingInterrupted event (empty - no data)
 */
export interface VoiceRecordingInterruptedEvent {}

/**
 * Event payload for voiceRecordingInterruptionEnded event (empty - no data)
 */
export interface VoiceRecordingInterruptionEndedEvent {}

export interface VoiceRecorderPlugin {
  canDeviceVoiceRecord(): Promise<GenericResponse>;

  requestAudioRecordingPermission(): Promise<GenericResponse>;

  hasAudioRecordingPermission(): Promise<GenericResponse>;

  startRecording(options?: RecordingOptions): Promise<GenericResponse>;

  stopRecording(): Promise<RecordingData>;

  pauseRecording(): Promise<GenericResponse>;

  resumeRecording(): Promise<GenericResponse>;

  getCurrentStatus(): Promise<CurrentRecordingStatus>;

  /**
   * Listen for audio recording interruptions (e.g., phone calls, other apps using microphone).
   * Available on iOS and Android only.
   *
   * @param eventName - The name of the event to listen for
   * @param listenerFunc - The callback function to invoke when the event occurs
   * @returns A promise that resolves to a PluginListenerHandle
   */
  addListener(
    eventName: 'voiceRecordingInterrupted',
    listenerFunc: (event: VoiceRecordingInterruptedEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Listen for audio recording interruption end events.
   * Available on iOS and Android only.
   *
   * @param eventName - The name of the event to listen for
   * @param listenerFunc - The callback function to invoke when the event occurs
   * @returns A promise that resolves to a PluginListenerHandle
   */
  addListener(
    eventName: 'voiceRecordingInterruptionEnded',
    listenerFunc: (event: VoiceRecordingInterruptionEndedEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Remove all listeners for this plugin.
   */
  removeAllListeners(): Promise<void>;

  // --- 核心新增：音量输出 ---
  addListener(eventName: 'onVolumeChange', listenerFunc: (data: { value: number }) => void): Promise<PluginListenerHandle>;
  addListener(eventName: 'voiceRecordingInterrupted', listenerFunc: () => void): Promise<PluginListenerHandle>;
   // --- 新增结束 ---
}
