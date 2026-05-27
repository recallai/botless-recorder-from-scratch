import type { MeetingProviderAdapter, MeetingCandidate } from "./types";
import { ChromeTabDetector } from "./chrome-tab-detector";

const MEET_URL_PATTERN = /^https:\/\/meet\.google\.com\/([a-z]{3}-[a-z]{4}-[a-z]{3})([/?#].*)?$/;

export class GoogleMeetAdapter implements MeetingProviderAdapter {
  constructor(private readonly chromeTabs: ChromeTabDetector) {}

  async detect(): Promise<MeetingCandidate | null> {
    const tabs = (await this.chromeTabs.readTabs())
      .filter((tab) => MEET_URL_PATTERN.test(tab.url))
      .sort((left, right) => this.rankTab(right) - this.rankTab(left));

    for (const tab of tabs) {
      const match = tab.url.match(MEET_URL_PATTERN);

      if (!match) {
        continue;
      }

      return {
        id: `google-meet:${match[1]}`,
        provider: "google-meet",
        title: tab.title,
        url: tab.url,
        browser: "Google Chrome",
        captureStrategy: "browser-window",
        matchTokens: [match[1], tab.title, "google meet"],
        windowIndex: tab.windowIndex,
        isFrontmostWindow: tab.isFrontmostWindow,
        isActiveTab: tab.isActiveTab
      };
    }

    return null;
  }

  private rankTab(tab: { isFrontmostWindow: boolean; isActiveTab: boolean }): number {
    return (tab.isFrontmostWindow ? 2 : 0) + (tab.isActiveTab ? 1 : 0);
  }
}
