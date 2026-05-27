import { contextBridge, ipcRenderer } from "electron";

import {
  IPC_CHANNELS,
  type MeetingCandidate,
  type NativeCaptureSourceSnapshot,
  type NativeRecorderState,
  type PermissionsSnapshot,
  type PrepareRecordingSessionRequest,
  type PrepareBrowserMeetingSurfaceRequest,
  type PrepareBrowserMeetingSurfaceResult,
  type PreparedRecordingSession,
  type StopNativeRecordingRequest,
  type StartNativeRecordingRequest
} from "../shared/ipc";

const api = {
  async detectMeeting(): Promise<MeetingCandidate | null> {
    return ipcRenderer.invoke(IPC_CHANNELS.detectMeeting) as Promise<MeetingCandidate | null>;
  },
  async getPermissions(): Promise<PermissionsSnapshot> {
    return ipcRenderer.invoke(IPC_CHANNELS.getPermissions) as Promise<PermissionsSnapshot>;
  },
  async getRecorderState(): Promise<NativeRecorderState> {
    return ipcRenderer.invoke(IPC_CHANNELS.getRecorderState) as Promise<NativeRecorderState>;
  },
  async listNativeCaptureSources(): Promise<NativeCaptureSourceSnapshot[]> {
    return ipcRenderer.invoke(IPC_CHANNELS.listNativeCaptureSources) as Promise<NativeCaptureSourceSnapshot[]>;
  },
  async prepareBrowserMeetingSurface(request: PrepareBrowserMeetingSurfaceRequest): Promise<PrepareBrowserMeetingSurfaceResult> {
    return ipcRenderer.invoke(IPC_CHANNELS.prepareBrowserMeetingSurface, request) as Promise<PrepareBrowserMeetingSurfaceResult>;
  },
  log(message: string) {
    ipcRenderer.send(IPC_CHANNELS.log, message);
  },
  openSystemSettings(target: "microphone" | "screen" | "automation") {
    return ipcRenderer.invoke(IPC_CHANNELS.openSystemSettings, target);
  },
  prepareSession(request?: PrepareRecordingSessionRequest): Promise<PreparedRecordingSession> {
    return ipcRenderer.invoke(IPC_CHANNELS.prepareSession, request) as Promise<PreparedRecordingSession>;
  },
  requestMicrophoneAccess(): Promise<boolean> {
    return ipcRenderer.invoke(IPC_CHANNELS.requestMicrophoneAccess) as Promise<boolean>;
  },
  startNativeRecording(request: StartNativeRecordingRequest): Promise<NativeRecorderState> {
    return ipcRenderer.invoke(IPC_CHANNELS.startNativeRecording, request) as Promise<NativeRecorderState>;
  },
  stopNativeRecording(request?: StopNativeRecordingRequest): Promise<NativeRecorderState> {
    return ipcRenderer.invoke(IPC_CHANNELS.stopNativeRecording, request) as Promise<NativeRecorderState>;
  }
};

contextBridge.exposeInMainWorld("botlessNotetaker", api);

declare global {
  interface Window {
    botlessNotetaker: typeof api;
  }
}
