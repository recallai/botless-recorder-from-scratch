type RecorderState = "idle" | "detecting" | "blocked" | "recording" | "error";
type MediaAccessStatus = "not-determined" | "granted" | "denied" | "restricted" | "unknown";
type AutomationStatus = "granted" | "denied" | "unknown";
type NativeCaptureSourceKind = "display" | "window";
type NativeRecorderStatus = "idle" | "starting" | "recording" | "stopping" | "error";
type MeetingProvider = "google-meet" | "zoom-browser" | "zoom-app";
type StopNativeRecordingRequest = {
  finalizeSession?: boolean;
  sessionId?: string;
};

interface MeetingCandidate {
  id: string;
  provider: MeetingProvider;
  title: string;
  url?: string;
  browser?: "Google Chrome";
  owningApplication?: string;
  captureStrategy: "browser-window" | "native-window";
  matchTokens: string[];
  windowIndex?: number;
  isFrontmostWindow?: boolean;
  isActiveTab?: boolean;
}

interface PermissionsSnapshot {
  platform: string;
  microphone: MediaAccessStatus;
  screen: MediaAccessStatus;
  chromeAutomation: AutomationStatus;
}

interface NativeCaptureSourceSnapshot {
  id: string;
  kind: NativeCaptureSourceKind;
  name: string;
  owningApplication?: string;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
}

interface PreparedRecordingSession {
  sessionId: string;
  directoryPath: string;
  rootDirectoryPath: string;
  segmentIndex: number;
  audioPath: string;
  videoPath: string;
  transcriptPath: string;
  transcriptJsonPath: string;
}

interface NativeRecorderState {
  status: NativeRecorderStatus;
  sessionId?: string;
  sourceId?: string;
  sourceName?: string;
  audioSummary?: string;
  videoPath?: string;
  audioPath?: string;
  lastError?: string;
}

interface StartNativeRecordingRequest {
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

interface PreparedMeetingCapture {
  meeting: MeetingCandidate;
  allowAlternateSurfaceSwitch: boolean;
  alternateSurfaceMode: boolean;
}

interface BotlessNotetakerApi {
  detectMeeting(): Promise<MeetingCandidate | null>;
  getPermissions(): Promise<PermissionsSnapshot>;
  getRecorderState(): Promise<NativeRecorderState>;
  listNativeCaptureSources(): Promise<NativeCaptureSourceSnapshot[]>;
  log(message: string): void;
  openSystemSettings(target: "microphone" | "screen" | "automation"): Promise<void>;
  prepareBrowserMeetingSurface(request: { provider: MeetingProvider; meetingUrl: string }): Promise<{ ok: boolean; message: string }>;
  prepareSession(request?: { existingSessionId?: string }): Promise<PreparedRecordingSession>;
  requestMicrophoneAccess(): Promise<boolean>;
  startNativeRecording(request: StartNativeRecordingRequest): Promise<NativeRecorderState>;
  stopNativeRecording(request?: StopNativeRecordingRequest): Promise<NativeRecorderState>;
}

interface Window {
  botlessNotetaker: BotlessNotetakerApi;
}

const DETECTION_INTERVAL_MS = 1_000;
const NATIVE_RETRY_BACKOFF_MS = 30_000;
const RECORDING_DETECTION_GRACE_MS = 20_000;
const DEBUG_CAPTURE_ONLY = true;
const GOOGLE_MEET_POPUP_SETTLE_MS = 750;
const ALTERNATE_SURFACE_CONFIRMATION_COUNT = 2;
const STABLE_POPUP_SURFACE_CONFIRMATION_COUNT = 1;
const MIN_STABLE_ALTERNATE_SURFACE_WIDTH = 480;
const MIN_STABLE_ALTERNATE_SURFACE_HEIGHT = 360;
const GOOGLE_MEET_POPUP_FALLBACK_MIN_WIDTH = 250;
const GOOGLE_MEET_POPUP_FALLBACK_MAX_WIDTH = 450;
const GOOGLE_MEET_POPUP_FALLBACK_MIN_HEIGHT = 250;
const GOOGLE_MEET_POPUP_FALLBACK_MAX_HEIGHT = 500;
const POPUP_SURFACE_LOSS_ERROR = "Failed to find any displays or windows to capture";
const POPUP_SURFACE_RECOVERY_GRACE_MS = 30_000;

// The renderer keeps one logical recording session alive across source switches.
// Each switch creates a new native segment under the same session root, and the
// main process merges those segments after the final stop.
class RecorderController {
  private readonly statusElement = this.getElement("status");
  private readonly detailElement = this.getElement("detail");
  private readonly sourceElement = this.getElement("source");
  private readonly outputElement = this.getElement("output");
  private readonly audioElement = this.getElement("audio");
  private readonly audioInputElement = this.getElement("audio-input");
  private readonly permissionsElement = this.getElement("permissions");
  private readonly refreshButton = this.getButton("refresh-permissions");
  private readonly screenButton = this.getButton("open-screen-settings");
  private readonly automationButton = this.getButton("open-automation-settings");
  private readonly microphoneButton = this.getButton("request-microphone");

  private activeMeetingCode: string | null = null;
  private syncInFlight = false;
  private retryBlockedUntil = 0;
  private lastConfirmedMeetingAt = 0;
  private pendingAlternateSourceId: string | null = null;
  private pendingAlternateSourceCount = 0;
  private activeSession: PreparedRecordingSession | null = null;

  start(): void {
    this.installActions();
    void this.refreshPermissions();

    this.setState("detecting", "Watching for supported meetings");
    window.setInterval(() => {
      void this.sync();
    }, DETECTION_INTERVAL_MS);

    void this.sync();
  }

  private installActions(): void {
    this.refreshButton.addEventListener("click", () => {
      void this.refreshPermissions();
    });

    this.screenButton.addEventListener("click", () => {
      void this.api.openSystemSettings("screen");
    });

    this.automationButton.addEventListener("click", () => {
      void this.api.openSystemSettings("automation");
    });

    this.microphoneButton.addEventListener("click", () => {
      void this.requestMicrophone();
    });
  }

  private async requestMicrophone(): Promise<void> {
    await this.api.requestMicrophoneAccess();
    await this.refreshPermissions();
  }

  private async refreshPermissions(): Promise<PermissionsSnapshot> {
    const permissions = await this.api.getPermissions();
    this.permissionsElement.textContent = this.formatPermissions(permissions);
    return permissions;
  }

  private async sync(): Promise<void> {
    if (this.syncInFlight) {
      return;
    }

    this.syncInFlight = true;

    try {
      const permissions = await this.refreshPermissions();
      const blocker = this.getBlocker(permissions);
      const recorderState = await this.api.getRecorderState();
      const now = Date.now();
      const awaitingPopupSurfaceRecovery =
        this.activeMeetingCode !== null &&
        (recorderState.lastError ?? "").includes(POPUP_SURFACE_LOSS_ERROR) &&
        now - this.lastConfirmedMeetingAt < POPUP_SURFACE_RECOVERY_GRACE_MS;

      if (blocker) {
        this.api.log(`Stopping recorder because permissions are blocked: ${blocker}`);
        await this.stopRecording();
        this.setState("blocked", blocker);
        return;
      }

      const meeting = await this.api.detectMeeting();

      if (!meeting) {
        if (awaitingPopupSurfaceRecovery) {
          this.api.log(
            `Waiting for Google Meet to reappear after popup surface loss (${Math.ceil((POPUP_SURFACE_RECOVERY_GRACE_MS - (now - this.lastConfirmedMeetingAt)) / 1000)}s recovery grace left)`
          );
          this.setState("detecting", "Recovering from Google Meet popup surface loss");
          this.detailElement.textContent = "Waiting for the main Google Meet surface to become detectable again";
          this.sourceElement.textContent = recorderState.sourceName ?? "Last popup surface";
          this.audioElement.textContent = recorderState.audioSummary ?? "Waiting to restart capture";
          return;
        }

        if (recorderState.status === "recording" && this.activeMeetingCode && now - this.lastConfirmedMeetingAt < RECORDING_DETECTION_GRACE_MS) {
          this.setState("recording", "Recording in progress");
          this.detailElement.textContent = `Waiting for meeting confirmation before stopping (${Math.ceil((RECORDING_DETECTION_GRACE_MS - (now - this.lastConfirmedMeetingAt)) / 1000)}s grace left)`;
          this.sourceElement.textContent = recorderState.sourceName ?? "Unknown source";
          this.audioElement.textContent = recorderState.audioSummary ?? "Waiting for helper audio summary";
          return;
        }

        this.api.log("Stopping recorder because no supported meeting was detected during sync");
        await this.stopRecording();
        this.setState("detecting", "No supported meeting detected");
        this.sourceElement.textContent = "Open Google Meet or Zoom, then keep the selected meeting surface visible";
        this.audioElement.textContent = "No active native recorder session";
        this.audioInputElement.textContent = "Google Meet and Zoom in browser require the meeting tab to stay active in its window";
        return;
      }

      this.lastConfirmedMeetingAt = now;

      if (
        recorderState.status === "error" &&
        meeting.provider === "google-meet" &&
        this.activeMeetingCode === meeting.id &&
        (recorderState.lastError ?? "").includes(POPUP_SURFACE_LOSS_ERROR)
      ) {
        this.api.log(
          `Recovering from Google Meet popup surface loss by restarting onto the currently detected meeting surface: activeMeeting=${this.activeMeetingCode} source=${recorderState.sourceId ?? "unknown"}`
        );
        await this.stopRecording(false);
        await this.startRecording(meeting);
        return;
      }

      if (recorderState.status === "error") {
        this.retryBlockedUntil = Date.now() + NATIVE_RETRY_BACKOFF_MS;
        this.setState("error", recorderState.lastError ?? "Native recorder failed");
        this.sourceElement.textContent = recorderState.sourceName ?? "Native helper failed before confirming a source";
        this.audioElement.textContent = recorderState.audioSummary ?? "No native audio summary available";
        this.audioInputElement.textContent = "Retry paused after native recorder failure";
        return;
      }

      if (recorderState.status === "recording" && recorderState.sessionId && this.activeMeetingCode === meeting.id) {
        if (meeting.provider === "google-meet" && meeting.captureStrategy === "browser-window" && meeting.isActiveTab === false) {
          // When the Meet tab is no longer active, try to follow a smaller Meet
          // surface like PiP/miniplayer instead of blindly staying on the full
          // browser window that now shows unrelated content.
          const preparedCapture = await this.prepareMeetingForCapture(meeting);
          const preparedMeeting = preparedCapture.meeting;
          this.api.log(
            `Evaluating Google Meet alternate surfaces: detectedActiveTab=${meeting.isActiveTab ? "yes" : "no"} preparedActiveTab=${preparedMeeting.isActiveTab ? "yes" : "no"} allowAlternateSwitch=${preparedCapture.allowAlternateSurfaceSwitch ? "yes" : "no"} alternateSurfaceMode=${preparedCapture.alternateSurfaceMode ? "yes" : "no"} currentSource=${recorderState.sourceId ?? "unknown"}`
          );
          const bestCandidate = await this.findBestCaptureCandidate(
            preparedMeeting,
            preparedCapture.allowAlternateSurfaceSwitch,
            preparedCapture.alternateSurfaceMode
          );

          if (bestCandidate && bestCandidate.score >= 95 && bestCandidate.source.id !== recorderState.sourceId) {
            const confirmationCount = this.observeAlternateSurface(bestCandidate.source.id);
            const requiredConfirmations = this.requiredAlternateSurfaceConfirmations(
              bestCandidate.source,
              preparedMeeting,
              preparedCapture.allowAlternateSurfaceSwitch
            );
            const allowSurfaceSwitch = confirmationCount >= requiredConfirmations;

            if (!allowSurfaceSwitch) {
              this.api.log(
                `Observed alternate Google Meet surface ${bestCandidate.source.id} score=${bestCandidate.score}; waiting for ${requiredConfirmations - confirmationCount} more confirmation(s) before switching`
              );
              await this.logRankedSources(preparedMeeting, "drift");
            } else {
            this.api.log(
              `Restarting recorder to follow alternate Google Meet surface: oldSource=${recorderState.sourceId ?? "unknown"} newSource=${bestCandidate.source.id} score=${bestCandidate.score}`
            );
            await this.stopRecording(false);
            await this.startRecording(preparedMeeting);
            return;
            }
          } else {
            this.resetAlternateSurfaceObservation();
          }

          await this.logRankedSources(preparedMeeting, "drift");
        }

        this.setState("recording", `Recording ${this.formatMeetingLabel(meeting)}`);
        this.detailElement.textContent = `${this.formatMeetingLocation(meeting)} · native helper active`;
        this.sourceElement.textContent = recorderState.sourceName ?? "Unknown source";
        this.audioElement.textContent = recorderState.audioSummary ?? "Waiting for helper audio summary";
        return;
      }

      if (recorderState.status === "starting" || recorderState.status === "stopping") {
        this.setState("detecting", `Recorder ${recorderState.status}`);
        return;
      }

      if (Date.now() < this.retryBlockedUntil) {
        const secondsRemaining = Math.ceil((this.retryBlockedUntil - Date.now()) / 1000);
        this.setState("error", `Native recorder retry paused for ${secondsRemaining}s after failure`);
        return;
      }

      this.api.log(`Restarting recorder because detected meeting changed or recorder was not active: provider=${meeting.provider} id=${meeting.id} recorderState=${recorderState.status} activeMeeting=${this.activeMeetingCode ?? "none"}`);
      await this.stopRecording(this.activeMeetingCode !== meeting.id);
      await this.startRecording(meeting);
    } catch (error) {
      if (String(error).toLowerCase().includes("popup")) {
        this.retryBlockedUntil = Date.now() + 20_000;
      }
      await this.stopRecording();
      this.setState("error", String(error));
      this.api.log(`Recorder sync failed: ${String(error)}`);
    } finally {
      this.syncInFlight = false;
    }
  }

  private async startRecording(meeting: MeetingCandidate): Promise<void> {
    const preparedMeeting = (await this.prepareMeetingForCapture(meeting)).meeting;
    const source = await this.findCaptureSource(preparedMeeting);

    if (!source) {
      this.setState("error", `No native source matched "${preparedMeeting.title}"`);
      this.sourceElement.textContent = "Keep the meeting window visible on screen";
      return;
    }

    const session = await this.api.prepareSession({
      existingSessionId: this.activeSession?.sessionId
    });
    const state = await this.api.startNativeRecording({
      sourceId: source.id,
      session,
      captureMicrophone: true,
      meetingUrl: preparedMeeting.url,
      debugCaptureOnly: DEBUG_CAPTURE_ONLY
    });

    this.activeMeetingCode = preparedMeeting.id;
    this.activeSession = session;
    this.lastConfirmedMeetingAt = Date.now();
    this.resetAlternateSurfaceObservation();
    this.setState("detecting", `Starting ${this.formatMeetingLabel(preparedMeeting)} recording`);
    this.detailElement.textContent = `${this.recordingDetail(preparedMeeting)} · waiting for native helper confirmation`;
    this.sourceElement.textContent = source.name;
    this.audioElement.textContent = state.audioSummary ?? "Native helper is preparing audio capture";
    this.audioInputElement.textContent = DEBUG_CAPTURE_ONLY
      ? "Stable probe path: system audio and microphone requested"
      : "Mic capture requested in native helper";
    this.outputElement.textContent = session.rootDirectoryPath;
    this.api.log(
      `Started native recording ${this.formatMeetingLocation(preparedMeeting)} from source ${source.name} id=${source.id} app=${source.owningApplication ?? "unknown"} size=${source.width ?? "?"}x${source.height ?? "?"}`
    );
    await this.logRankedSources(preparedMeeting, "start");
  }

  private async stopRecording(finalizeSession = true): Promise<void> {
    const state = await this.api.getRecorderState();

    if (state.status === "idle") {
      this.activeMeetingCode = null;
      this.lastConfirmedMeetingAt = 0;
      this.resetAlternateSurfaceObservation();
      if (finalizeSession) {
        this.activeSession = null;
      }
      this.outputElement.textContent = "No active session";
      return;
    }

    await this.api.stopNativeRecording({
      finalizeSession,
      sessionId: this.activeSession?.sessionId
    });

    if (finalizeSession) {
      this.activeMeetingCode = null;
      this.lastConfirmedMeetingAt = 0;
      this.activeSession = null;
      this.outputElement.textContent = "No active session";
    }

    this.resetAlternateSurfaceObservation();
  }

  private async findCaptureSource(meeting: MeetingCandidate): Promise<NativeCaptureSourceSnapshot | null> {
    const bestCandidate = await this.findBestCaptureCandidate(meeting, true, false);
    return bestCandidate?.source ?? null;
  }

  private async prepareMeetingForCapture(meeting: MeetingCandidate): Promise<PreparedMeetingCapture> {
    if (meeting.provider === "google-meet" && meeting.url && meeting.isActiveTab === false) {
      // This asks the Chrome automation layer to open or reveal a smaller Meet
      // surface before we rank native windows. If it fails, the recorder can
      // still fall back to a stable popup-sized Meet window when one appears.
      const result = await this.api.prepareBrowserMeetingSurface({
        provider: meeting.provider,
        meetingUrl: meeting.url
      });

      this.api.log(`Google Meet surface preparation result: ok=${result.ok ? "yes" : "no"} message=${result.message}`);

      if (result.ok) {
        await new Promise((resolve) => window.setTimeout(resolve, GOOGLE_MEET_POPUP_SETTLE_MS));
        return {
          meeting,
          allowAlternateSurfaceSwitch: true,
          alternateSurfaceMode: true
        };
      }

      return {
        meeting,
        allowAlternateSurfaceSwitch: false,
        alternateSurfaceMode: true
      };
    }

    return {
      meeting,
      allowAlternateSurfaceSwitch: true,
      alternateSurfaceMode: false
    };
  }

  private async findBestCaptureCandidate(
    meeting: MeetingCandidate,
    allowTinyAlternateSurface: boolean,
    alternateSurfaceMode: boolean
  ): Promise<{ source: NativeCaptureSourceSnapshot; score: number } | null> {
    const sources = await this.api.listNativeCaptureSources();
    const rankedWithEligibility = sources
      .map((source) => ({
        source,
        score: this.scoreSource(source, meeting),
        eligible: this.isEligibleAlternateSurface(source, meeting, allowTinyAlternateSurface, alternateSurfaceMode)
      }))
      .filter((entry) => entry.score > 0);

    if (meeting.provider === "google-meet" && meeting.captureStrategy === "browser-window" && alternateSurfaceMode) {
      const debugSummary = rankedWithEligibility
        .slice()
        .sort((left, right) => right.score - left.score)
        .slice(0, 5)
        .map((entry) => {
          const width = entry.source.width ?? 0;
          const height = entry.source.height ?? 0;
          return `${entry.source.id}:${entry.source.name}:${width}x${height}:score=${entry.score}:eligible=${entry.eligible ? "yes" : "no"}`;
        })
        .join(" | ");

      this.api.log(
        `Alternate surface candidates for ${meeting.id} activeTab=${meeting.isActiveTab ? "yes" : "no"} allowTiny=${allowTinyAlternateSurface ? "yes" : "no"} -> ${debugSummary || "none"}`
      );
    }

    const ranked = rankedWithEligibility
      .filter((entry) => entry.eligible)
      .sort((left, right) => right.score - left.score);

    return ranked[0] ?? null;
  }

  private async logRankedSources(meeting: MeetingCandidate, reason: "start" | "drift"): Promise<void> {
    if (meeting.captureStrategy !== "browser-window") {
      return;
    }

    const sources = await this.api.listNativeCaptureSources();
    const ranked = sources
      .map((source) => ({ source, score: this.scoreSource(source, meeting) }))
      .filter((entry) => entry.score > 0)
      .sort((left, right) => right.score - left.score)
      .slice(0, 5)
      .map((entry) => `${entry.source.id}:${entry.source.name}:${entry.score}`);

    this.api.log(
      `Ranked browser capture sources (${reason}) for ${meeting.id} activeTab=${meeting.isActiveTab ? "yes" : "no"} -> ${ranked.join(" | ")}`
    );
  }

  private scoreSource(source: NativeCaptureSourceSnapshot, meeting: MeetingCandidate): number {
    const normalizedSourceTitle = this.normalizeTitle(source.name);
    const normalizedMeetingTitle = this.normalizeTitle(meeting.title);
    const owningApplication = source.owningApplication?.toLowerCase() ?? "";
    const normalizedTokens = meeting.matchTokens
      .map((token) => this.normalizeTitle(token))
      .filter((token) => token.length > 0);

    if (meeting.captureStrategy === "browser-window") {
      const isChromeWindow = owningApplication.includes("google chrome");
      const width = source.width ?? 0;
      const height = source.height ?? 0;
      const smallerWindowBonus = width > 0 && height > 0 && width <= 1100 && height <= 900 ? 25 : 0;
      const titleTokenMatch = normalizedTokens.some((token) => normalizedSourceTitle.includes(token));
      const titleLooksMeetingSpecific = normalizedSourceTitle.includes("google meet") || normalizedSourceTitle.includes("meet");

      if (!isChromeWindow || source.kind !== "window") {
        return 0;
      }

      if (meeting.provider === "google-meet" && meeting.isActiveTab === false) {
        if (normalizedSourceTitle === normalizedMeetingTitle) {
          return 130 + smallerWindowBonus;
        }

        if (titleTokenMatch) {
          return 120 + smallerWindowBonus;
        }

        if (titleLooksMeetingSpecific) {
          return 95 + smallerWindowBonus;
        }

        return smallerWindowBonus > 0 ? 40 + smallerWindowBonus : 0;
      }

      if (normalizedSourceTitle === normalizedMeetingTitle) {
        return 100;
      }

      if (titleTokenMatch) {
        return 80;
      }

      if (meeting.provider === "google-meet" && normalizedSourceTitle.includes("google meet")) {
        return 70;
      }

      if (meeting.provider === "zoom-browser" && normalizedSourceTitle.includes("zoom")) {
        return 70;
      }

      return 0;
    }

    if (meeting.captureStrategy === "native-window") {
      const isZoomWindow = owningApplication.includes("zoom");

      if (!isZoomWindow || source.kind !== "window") {
        return 0;
      }

      if (normalizedSourceTitle === normalizedMeetingTitle) {
        return 100;
      }

      if (normalizedTokens.some((token) => normalizedSourceTitle.includes(token))) {
        return 80;
      }

      if (normalizedSourceTitle.includes("zoom meeting")) {
        return 70;
      }

      return 40;
    }

    return source.kind === "display" ? 10 : 0;
  }

  private normalizeTitle(value: string): string {
    return value
      .toLowerCase()
      .replace(/\s+-\s+google chrome$/, "")
      .replace(/\s+/g, " ")
      .trim();
  }

  private isEligibleAlternateSurface(
    source: NativeCaptureSourceSnapshot,
    meeting: MeetingCandidate,
    allowTinyAlternateSurface: boolean,
    alternateSurfaceMode: boolean
  ): boolean {
    if (meeting.provider !== "google-meet" || !alternateSurfaceMode) {
      return true;
    }

    if (allowTinyAlternateSurface) {
      return true;
    }

    const width = source.width ?? 0;
    const height = source.height ?? 0;
    const looksLikeStableMeetingPopup = this.isLikelyStableGoogleMeetPopupSource(source, meeting);

    if (looksLikeStableMeetingPopup) {
      this.api.log(
        `Allowing stable Google Meet popup fallback surface ${source.id} (${source.name}) size=${width}x${height} even though popup/miniplayer preparation did not succeed`
      );
      return true;
    }

    const eligible = width >= MIN_STABLE_ALTERNATE_SURFACE_WIDTH && height >= MIN_STABLE_ALTERNATE_SURFACE_HEIGHT;

    if (!eligible) {
      this.api.log(
        `Rejecting tiny alternate Google Meet surface ${source.id} (${source.name}) size=${width}x${height} because popup/miniplayer preparation did not succeed`
      );
    }

    return eligible;
  }

  private requiredAlternateSurfaceConfirmations(
    source: NativeCaptureSourceSnapshot,
    meeting: MeetingCandidate,
    allowAlternateSurfaceSwitch: boolean
  ): number {
    if (allowAlternateSurfaceSwitch) {
      return STABLE_POPUP_SURFACE_CONFIRMATION_COUNT;
    }

    if (this.isLikelyStableGoogleMeetPopupSource(source, meeting)) {
      return STABLE_POPUP_SURFACE_CONFIRMATION_COUNT;
    }

    return ALTERNATE_SURFACE_CONFIRMATION_COUNT;
  }

  private isLikelyStableGoogleMeetPopupSource(source: NativeCaptureSourceSnapshot, meeting: MeetingCandidate): boolean {
    const width = source.width ?? 0;
    const height = source.height ?? 0;
    const normalizedSourceTitle = this.normalizeTitle(source.name);
    const normalizedMeetingTitle = this.normalizeTitle(meeting.title);

    return (
      normalizedSourceTitle === normalizedMeetingTitle &&
      width >= GOOGLE_MEET_POPUP_FALLBACK_MIN_WIDTH &&
      width <= GOOGLE_MEET_POPUP_FALLBACK_MAX_WIDTH &&
      height >= GOOGLE_MEET_POPUP_FALLBACK_MIN_HEIGHT &&
      height <= GOOGLE_MEET_POPUP_FALLBACK_MAX_HEIGHT
    );
  }

  private observeAlternateSurface(sourceId: string): number {
    if (this.pendingAlternateSourceId === sourceId) {
      this.pendingAlternateSourceCount += 1;
      return this.pendingAlternateSourceCount;
    }

    this.pendingAlternateSourceId = sourceId;
    this.pendingAlternateSourceCount = 1;
    return this.pendingAlternateSourceCount;
  }

  private resetAlternateSurfaceObservation(): void {
    this.pendingAlternateSourceId = null;
    this.pendingAlternateSourceCount = 0;
  }

  private getBlocker(permissions: PermissionsSnapshot): string | null {
    if (permissions.screen === "denied" || permissions.screen === "restricted") {
      return "Allow Screen Recording for Botless Notetaker in System Settings";
    }

    return null;
  }

  private formatPermissions(permissions: PermissionsSnapshot): string {
    return [
      `screen: ${permissions.screen}`,
      `microphone: ${permissions.microphone}`,
      `chrome automation: ${permissions.chromeAutomation}`
    ].join(" | ");
  }

  private formatMeetingLabel(meeting: MeetingCandidate): string {
    switch (meeting.provider) {
      case "google-meet":
        return "Google Meet";
      case "zoom-browser":
        return "Zoom (browser)";
      case "zoom-app":
        return "Zoom app";
    }
  }

  private formatMeetingLocation(meeting: MeetingCandidate): string {
    return meeting.url ?? meeting.title;
  }

  private recordingDetail(meeting: MeetingCandidate): string {
    const base = `${this.formatMeetingLocation(meeting)} · native helper`;

    if (meeting.captureStrategy === "browser-window") {
      return `${base} · keep the meeting tab active in that browser window`;
    }

    return base;
  }

  private setState(state: RecorderState, detail: string): void {
    this.statusElement.dataset.state = state;
    this.statusElement.textContent = state.toUpperCase();
    this.detailElement.textContent = detail;
  }

  private getElement(id: string): HTMLElement {
    const element = document.getElementById(id);

    if (!element) {
      throw new Error(`Missing required element: ${id}`);
    }

    return element;
  }

  private getButton(id: string): HTMLButtonElement {
    const element = document.getElementById(id);

    if (!(element instanceof HTMLButtonElement)) {
      throw new Error(`Missing required button: ${id}`);
    }

    return element;
  }

  private get api(): BotlessNotetakerApi {
    if (!window.botlessNotetaker) {
      throw new Error("Preload bridge missing: window.botlessNotetaker was not injected. Check terminal output for a preload startup error.");
    }

    return window.botlessNotetaker;
  }
}

window.addEventListener("DOMContentLoaded", () => {
  const controller = new RecorderController();
  controller.start();
});
