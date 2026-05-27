import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

import { ChromeTabDetector } from "./providers/chrome-tab-detector";

interface TranscriptSession {
  meetingUrl: string;
  transcriptPath: string;
  transcriptJsonPath: string;
  startedAtMs: number;
  captionsEnabled: boolean;
  segments: TranscriptSegment[];
  lastSnapshot: CaptionSnapshot[];
  rowToSegmentIndex: Map<number, number>;
}

interface CaptionSnapshot {
  speaker: string;
  text: string;
}

interface TranscriptSegment {
  speaker: string;
  text: string;
  startMs: number;
  endMs: number;
}

const POLL_INTERVAL_MS = 1_000;
const RECENT_DUPLICATE_WINDOW_MS = 8_000;

export class GoogleMeetTranscriptRecorder {
  private activeSession: TranscriptSession | null = null;
  private pollTimer: NodeJS.Timeout | null = null;
  private pollInFlight = false;

  constructor(private readonly chromeTabs: ChromeTabDetector) {}

  async start(options: {
    meetingUrl: string;
    transcriptPath: string;
    transcriptJsonPath: string;
  }): Promise<void> {
    if (
      this.activeSession &&
      this.activeSession.meetingUrl === options.meetingUrl &&
      this.activeSession.transcriptPath === options.transcriptPath &&
      this.activeSession.transcriptJsonPath === options.transcriptJsonPath
    ) {
      return;
    }

    await this.stop();

    const session: TranscriptSession = {
      meetingUrl: options.meetingUrl,
      transcriptPath: options.transcriptPath,
      transcriptJsonPath: options.transcriptJsonPath,
      startedAtMs: Date.now(),
      captionsEnabled: false,
      segments: [],
      lastSnapshot: [],
      rowToSegmentIndex: new Map<number, number>()
    };

    this.activeSession = session;
    this.ensureParentDirectory(session.transcriptPath);
    this.ensureParentDirectory(session.transcriptJsonPath);

    const captionResult = await this.chromeTabs.ensureGoogleMeetCaptions(options.meetingUrl);
    session.captionsEnabled = captionResult.ok;

    if (!captionResult.ok) {
      console.warn(`[transcript] Unable to ensure Google Meet captions are enabled: ${captionResult.message}`);
    } else {
      console.log(`[transcript] Google Meet captions ready: ${captionResult.message}`);
    }

    await this.pollCaptions();
    this.pollTimer = setInterval(() => {
      void this.pollCaptions();
    }, POLL_INTERVAL_MS);
  }

  async stop(): Promise<void> {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }

    while (this.pollInFlight) {
      await new Promise((resolve) => setTimeout(resolve, 25));
    }

    if (this.activeSession) {
      this.persistTranscript(this.activeSession);
      console.log(`[transcript] Wrote diarized transcript to ${this.activeSession.transcriptPath}`);
    }

    this.activeSession = null;
  }

  private async pollCaptions(): Promise<void> {
    if (!this.activeSession || this.pollInFlight) {
      return;
    }

    this.pollInFlight = true;

    try {
      const session = this.activeSession;
      const captions = await this.chromeTabs.readGoogleMeetCaptions(session.meetingUrl);
      const nowMs = Date.now() - session.startedAtMs;

      if (captions.length === 0) {
        return;
      }

      const nextRowToSegmentIndex = new Map<number, number>();

      captions.forEach((caption, rowIndex) => {
        const previousCaption = session.lastSnapshot[rowIndex];
        const previousSegmentIndex = session.rowToSegmentIndex.get(rowIndex);
        const recentMatchIndex = this.findRecentExactMatch(session, caption, nowMs);

        if (
          typeof previousSegmentIndex === "number" &&
          this.canExtendSegment(session.segments[previousSegmentIndex], caption, previousCaption)
        ) {
          this.extendSegment(session.segments[previousSegmentIndex], caption.text, nowMs);
          nextRowToSegmentIndex.set(rowIndex, previousSegmentIndex);
          return;
        }

        if (typeof recentMatchIndex === "number") {
          this.extendSegment(session.segments[recentMatchIndex], caption.text, nowMs);
          nextRowToSegmentIndex.set(rowIndex, recentMatchIndex);
          return;
        }

        const lastSegment = session.segments.at(-1);

        if (this.canMergeWithLastSegment(lastSegment, caption)) {
          this.extendSegment(lastSegment as TranscriptSegment, caption.text, nowMs);
          nextRowToSegmentIndex.set(rowIndex, session.segments.length - 1);
          return;
        }

        session.segments.push({
          speaker: caption.speaker,
          text: caption.text,
          startMs: nowMs,
          endMs: nowMs
        });
        nextRowToSegmentIndex.set(rowIndex, session.segments.length - 1);
      });

      session.lastSnapshot = captions;
      session.rowToSegmentIndex = nextRowToSegmentIndex;
      this.persistTranscript(session);
    } finally {
      this.pollInFlight = false;
    }
  }

  private canExtendSegment(
    segment: TranscriptSegment | undefined,
    caption: CaptionSnapshot,
    previousCaption: CaptionSnapshot | undefined
  ): boolean {
    if (!segment || segment.speaker !== caption.speaker) {
      return false;
    }

    if (!previousCaption || previousCaption.speaker !== caption.speaker) {
      return false;
    }

    return this.isSameOrGrowingText(previousCaption.text, caption.text);
  }

  private canMergeWithLastSegment(segment: TranscriptSegment | undefined, caption: CaptionSnapshot): boolean {
    if (!segment || segment.speaker !== caption.speaker) {
      return false;
    }

    return this.isSameOrGrowingText(segment.text, caption.text);
  }

  private isSameOrGrowingText(previousText: string, nextText: string): boolean {
    return nextText === previousText || nextText.startsWith(previousText) || previousText.startsWith(nextText);
  }

  private extendSegment(segment: TranscriptSegment, text: string, endMs: number): void {
    if (text.length >= segment.text.length) {
      segment.text = text;
    }
    segment.endMs = endMs;
  }

  private findRecentExactMatch(
    session: TranscriptSession,
    caption: CaptionSnapshot,
    nowMs: number
  ): number | undefined {
    for (let index = session.segments.length - 1; index >= 0; index -= 1) {
      const segment = session.segments[index];

      if (nowMs - segment.endMs > RECENT_DUPLICATE_WINDOW_MS) {
        return undefined;
      }

      if (segment.speaker === caption.speaker && segment.text === caption.text) {
        return index;
      }
    }

    return undefined;
  }

  private persistTranscript(session: TranscriptSession): void {
    const textOutput = session.segments
      .map((segment) => `[${this.formatTimestamp(segment.startMs)}] ${segment.speaker}: ${segment.text}`)
      .join("\n");

    const jsonOutput = JSON.stringify(
      {
        meetingUrl: session.meetingUrl,
        captionsEnabled: session.captionsEnabled,
        generatedAt: new Date().toISOString(),
        segments: session.segments
      },
      null,
      2
    );

    writeFileSync(session.transcriptPath, textOutput, "utf8");
    writeFileSync(session.transcriptJsonPath, jsonOutput, "utf8");
  }

  private formatTimestamp(timestampMs: number): string {
    const totalSeconds = Math.max(0, Math.floor(timestampMs / 1000));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;

    if (hours > 0) {
      return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
    }

    return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
  }

  private ensureParentDirectory(filePath: string): void {
    mkdirSync(dirname(filePath), { recursive: true });
  }
}
