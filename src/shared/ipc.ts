export const IPC_CHANNELS = {
  detectMeeting: "detector:detect-meeting",
  getPermissions: "permissions:get",
  getRecorderState: "native-recorder:get-state",
  listNativeCaptureSources: "native-recorder:list-sources",
  prepareBrowserMeetingSurface: "browser-meeting:prepare-surface",
  openSystemSettings: "system:open-settings",
  prepareSession: "recording:prepare-session",
  requestMicrophoneAccess: "permissions:request-microphone",
  startNativeRecording: "native-recorder:start",
  stopNativeRecording: "native-recorder:stop",
  log: "app:log"
} as const;

export type PermissionStatus = "not-determined" | "granted" | "denied" | "restricted" | "unknown";
export type AutomationStatus = "granted" | "denied" | "unknown";
export type NativeCaptureSourceKind = "display" | "window";
export type NativeRecorderStatus = "idle" | "starting" | "recording" | "stopping" | "error";
export type MeetingProvider = "google-meet" | "zoom-browser" | "zoom-app";
export type CaptureStrategy = "browser-window" | "native-window";

export interface MeetingCandidate {
  id: string;
  provider: MeetingProvider;
  title: string;
  url?: string;
  browser?: "Google Chrome";
  owningApplication?: string;
  captureStrategy: CaptureStrategy;
  matchTokens: string[];
  windowIndex?: number;
  isFrontmostWindow?: boolean;
  isActiveTab?: boolean;
}

export interface PermissionsSnapshot {
  platform: NodeJS.Platform;
  microphone: PermissionStatus;
  screen: PermissionStatus;
  chromeAutomation: AutomationStatus;
}

export interface NativeCaptureSourceSnapshot {
  id: string;
  kind: NativeCaptureSourceKind;
  name: string;
  owningApplication?: string;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
}

export interface PreparedRecordingSession {
  sessionId: string;
  directoryPath: string;
  rootDirectoryPath: string;
  segmentIndex: number;
  audioPath: string;
  videoPath: string;
  transcriptPath: string;
  transcriptJsonPath: string;
}

export interface PrepareRecordingSessionRequest {
  existingSessionId?: string;
}

export interface StartNativeRecordingRequest {
  sourceId: string;
  session: PreparedRecordingSession;
  captureMicrophone: boolean;
  meetingUrl?: string;
  debugCaptureOnly?: boolean;
  cropX?: number;
  cropY?: number;
  cropWidth?: number;
  cropHeight?: number;
}

export interface NativeRecorderState {
  status: NativeRecorderStatus;
  sessionId?: string;
  sourceId?: string;
  sourceName?: string;
  audioSummary?: string;
  videoPath?: string;
  audioPath?: string;
  lastError?: string;
}

export interface StopNativeRecordingRequest {
  finalizeSession?: boolean;
  sessionId?: string;
}

export interface PrepareBrowserMeetingSurfaceRequest {
  provider: MeetingProvider;
  meetingUrl: string;
}

export interface PrepareBrowserMeetingSurfaceResult {
  ok: boolean;
  message: string;
}
