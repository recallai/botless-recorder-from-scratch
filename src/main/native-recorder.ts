import { execFile, spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { app } from "electron";
import { promisify } from "node:util";

import type {
  NativeCaptureSourceSnapshot,
  NativeRecorderState,
  StartNativeRecordingRequest
} from "../shared/ipc";

const execFileAsync = promisify(execFile);

interface HelperListSourcesResponse {
  sources: NativeCaptureSourceSnapshot[];
}

interface HelperEvent {
  type: string;
  message?: string;
  audioSummary?: string;
  sourceName?: string;
}

export class NativeRecorderManager {
  private helperProcess: ChildProcessByStdio<null, Readable, Readable> | null = null;
  private state: NativeRecorderState = { status: "idle" };
  private stopInFlight: Promise<NativeRecorderState> | null = null;
  private stdoutBuffer = "";

  async listSources(): Promise<NativeCaptureSourceSnapshot[]> {
    const helperPath = this.helperBinaryPath(false);
    const { stdout } = await execFileAsync(helperPath, ["list-sources"]);
    const parsed = JSON.parse(stdout) as HelperListSourcesResponse;
    return parsed.sources;
  }

  getState(): NativeRecorderState {
    return this.state;
  }

  async startRecording(request: StartNativeRecordingRequest): Promise<NativeRecorderState> {
    if (this.helperProcess) {
      throw new Error("Native recorder is already running");
    }

    const helperPath = this.helperBinaryPath(request.debugCaptureOnly === true);
    this.state = {
      status: "starting",
      sessionId: request.session.sessionId,
      sourceId: request.sourceId,
      videoPath: request.session.videoPath,
      audioPath: request.session.audioPath
    };

    // The app currently uses the probe-style helper in its main path because it
    // has been more stable for tab/PiP switching experiments than the original
    // full recorder helper.
    const args = request.debugCaptureOnly
      ? [
          "app-probe",
          "--source-id", request.sourceId,
          "--video-path", request.session.videoPath,
          "--audio-path", request.session.audioPath,
          "--capture-microphone", String(request.captureMicrophone)
        ]
      : [
          "record",
          "--source-id", request.sourceId,
          "--output-dir", request.session.directoryPath,
          "--video-path", request.session.videoPath,
          "--audio-path", request.session.audioPath,
          "--capture-microphone", String(request.captureMicrophone)
        ];

    if (request.meetingUrl) {
      args.push("--meeting-url", request.meetingUrl);
    }

    if (typeof request.cropX === "number" && typeof request.cropY === "number" && typeof request.cropWidth === "number" && typeof request.cropHeight === "number") {
      args.push(
        "--crop-x", String(request.cropX),
        "--crop-y", String(request.cropY),
        "--crop-width", String(request.cropWidth),
        "--crop-height", String(request.cropHeight)
      );
    }

    const child = spawn(helperPath, args, {
      stdio: ["ignore", "pipe", "pipe"]
    });

    this.helperProcess = child;
    this.stdoutBuffer = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");

    child.stdout.on("data", (chunk: string) => {
      this.consumeHelperStdout(chunk);
    });

    child.stderr.on("data", (chunk: string) => {
      const message = chunk.trim();

      if (message.length > 0) {
        console.error(`[native-recorder] ${message}`);
        this.state = {
          ...this.state,
          lastError: message
        };
      }
    });

    child.once("exit", (code, signal) => {
      console.log(`[native-recorder] Helper exited code=${code ?? "null"} signal=${signal ?? "null"} state=${this.state.status}`);
      const lastError = code === 0 || signal === "SIGINT" ? undefined : this.state.lastError ?? `Helper exited with code ${code ?? "null"}`;
      this.state = {
        ...this.state,
        status: lastError ? "error" : "idle",
        lastError
      };
      this.helperProcess = null;
    });

    return this.state;
  }

  async stopRecording(): Promise<NativeRecorderState> {
    if (this.stopInFlight) {
      return this.stopInFlight;
    }

    if (!this.helperProcess) {
      if (this.state.status !== "error") {
        this.state = { status: "idle" };
      }
      return this.state;
    }

    this.state = {
      ...this.state,
      status: "stopping"
    };

    const child = this.helperProcess;

    this.stopInFlight = new Promise<NativeRecorderState>((resolve) => {
      child.once("exit", () => {
        this.stopInFlight = null;
        resolve(this.state);
      });
      child.kill("SIGINT");
    });

    return this.stopInFlight;
  }

  private consumeHelperStdout(chunk: string): void {
    this.stdoutBuffer += chunk;
    const lines = this.stdoutBuffer.split("\n");
    this.stdoutBuffer = lines.pop() ?? "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.length === 0) {
        continue;
      }

      try {
        const event = JSON.parse(trimmed) as HelperEvent;
        this.applyHelperEvent(event);
      } catch {
        console.log(`[native-recorder] ${trimmed}`);
      }
    }
  }

  private applyHelperEvent(event: HelperEvent): void {
    switch (event.type) {
      case "recording-started":
        this.state = {
          ...this.state,
          status: "recording",
          sourceName: event.sourceName,
          audioSummary: event.audioSummary
        };
        break;
      case "recording-stopped":
        // A native segment can stop while the overall logical session continues.
        this.state = {
          ...this.state,
          status: "idle"
        };
        break;
      case "error":
        if (event.message) {
          console.error(`[native-recorder] ${event.message}`);
        }
        this.state = {
          ...this.state,
          status: "error",
          lastError: event.message ?? "Native recorder error"
        };
        break;
      case "debug":
        if (event.message) {
          console.log(`[native-recorder] ${event.message}`);
        }
        break;
      default:
        break;
    }
  }

  private helperBinaryPath(debugCaptureOnly = false): string {
    const binaryName = debugCaptureOnly ? "macos-window-probe" : "macos-recorder";
    const helperPath = join(app.getAppPath(), "dist", "native", binaryName);

    if (!existsSync(helperPath)) {
      throw new Error(`Native recorder helper not found at ${helperPath}`);
    }

    return helperPath;
  }
}
