import type { NativeCaptureSourceSnapshot } from "../../shared/ipc";

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

export interface MeetingProviderAdapter {
  detect(): Promise<MeetingCandidate | null>;
}

export interface ChromeTabSnapshot {
  title: string;
  url: string;
  windowIndex: number;
  isFrontmostWindow: boolean;
  isActiveTab: boolean;
}

export interface NativeMeetingWindowSnapshot {
  id: string;
  title: string;
  owningApplication: string;
}

export function captureSourceToNativeWindow(source: NativeCaptureSourceSnapshot): NativeMeetingWindowSnapshot | null {
  if (source.kind !== "window" || !source.owningApplication) {
    return null;
  }

  return {
    id: source.id,
    title: source.name,
    owningApplication: source.owningApplication
  };
}
