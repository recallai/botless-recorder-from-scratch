import type { MeetingCandidate, MeetingProviderAdapter } from "./types";
import { ChromeTabDetector } from "./chrome-tab-detector";

const ZOOM_BROWSER_PATTERNS = [
  /^https:\/\/([a-z0-9-]+\.)?zoom\.us\/wc\//,
  /^https:\/\/([a-z0-9-]+\.)?zoom\.us\/j\//,
  /^https:\/\/([a-z0-9-]+\.)?zoom\.us\/meeting\//
];

export class ZoomBrowserAdapter implements MeetingProviderAdapter {
  constructor(private readonly chromeTabs: ChromeTabDetector) {}

  async detect(): Promise<MeetingCandidate | null> {
    const tabs = (await this.chromeTabs.readTabs())
      .filter((tab) => tab.isActiveTab)
      .filter((tab) => ZOOM_BROWSER_PATTERNS.some((pattern) => pattern.test(tab.url)))
      .sort((left, right) => this.rankTab(right) - this.rankTab(left));

    for (const tab of tabs) {
      const zoomId = this.extractZoomId(tab.url);

      return {
        id: `zoom-browser:${zoomId ?? tab.windowIndex}`,
        provider: "zoom-browser",
        title: tab.title,
        url: tab.url,
        browser: "Google Chrome",
        captureStrategy: "browser-window",
        matchTokens: [zoomId ?? "", tab.title, "zoom"],
        windowIndex: tab.windowIndex,
        isFrontmostWindow: tab.isFrontmostWindow,
        isActiveTab: tab.isActiveTab
      };
    }

    return null;
  }

  private extractZoomId(url: string): string | null {
    const match = url.match(/\/(?:wc|j)\/([0-9]+)/);
    return match?.[1] ?? null;
  }

  private rankTab(tab: { isFrontmostWindow: boolean; isActiveTab: boolean }): number {
    return (tab.isFrontmostWindow ? 2 : 0) + (tab.isActiveTab ? 1 : 0);
  }
}
