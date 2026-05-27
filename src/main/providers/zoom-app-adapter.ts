import type { NativeCaptureSourceSnapshot } from "../../shared/ipc";
import type { MeetingCandidate, MeetingProviderAdapter } from "./types";
import { captureSourceToNativeWindow } from "./types";

type SourceLister = () => Promise<NativeCaptureSourceSnapshot[]>;

export class ZoomAppAdapter implements MeetingProviderAdapter {
  constructor(private readonly listSources: SourceLister) {}

  async detect(): Promise<MeetingCandidate | null> {
    const windows = (await this.listSources())
      .map(captureSourceToNativeWindow)
      .filter((window): window is NonNullable<typeof window> => window !== null)
      .filter((window) => this.isZoomApplication(window.owningApplication))
      .sort((left, right) => this.rankWindow(right) - this.rankWindow(left));

    const meetingWindow = windows.find((window) => this.looksLikeMeetingWindow(window.title));

    if (!meetingWindow) {
      return null;
    }

    return {
      id: `zoom-app:${meetingWindow.id}`,
      provider: "zoom-app",
      title: meetingWindow.title,
      owningApplication: meetingWindow.owningApplication,
      captureStrategy: "native-window",
      matchTokens: [meetingWindow.title, "zoom", "meeting"]
    };
  }

  private isZoomApplication(applicationName: string): boolean {
    const value = applicationName.toLowerCase();
    return value.includes("zoom");
  }

  private looksLikeMeetingWindow(title: string): boolean {
    const value = title.toLowerCase();

    if (value.includes("settings") || value.includes("preferences") || value.includes("update")) {
      return false;
    }

    return value.includes("zoom meeting") || value.includes("meeting") || value.includes("sharing") || value.includes("screen share");
  }

  private rankWindow(window: { title: string }): number {
    const value = window.title.toLowerCase();

    if (value.includes("zoom meeting")) {
      return 100;
    }

    if (value.includes("meeting")) {
      return 80;
    }

    if (value.includes("sharing") || value.includes("screen share")) {
      return 60;
    }

    return 10;
  }
}
