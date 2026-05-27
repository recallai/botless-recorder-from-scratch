import type { MeetingCandidate, MeetingProviderAdapter } from "./types";

export class ProviderManager {
  constructor(private readonly adapters: MeetingProviderAdapter[]) {}

  async detectMeeting(): Promise<MeetingCandidate | null> {
    for (const adapter of this.adapters) {
      const candidate = await adapter.detect();

      if (candidate) {
        console.log(`[detector] Detected ${candidate.provider} -> ${candidate.id} (${candidate.title})`);
        return candidate;
      }
    }

    console.log("[detector] No provider reported an active meeting");
    return null;
  }
}
