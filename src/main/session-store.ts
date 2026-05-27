import { copyFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { app } from "electron";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import type { PreparedRecordingSession, PrepareRecordingSessionRequest } from "../shared/ipc";

const execFileAsync = promisify(execFile);
const FFMPEG_PATH = "/opt/homebrew/bin/ffmpeg";

interface SessionGroup {
  sessionId: string;
  rootDirectoryPath: string;
  transcriptPath: string;
  transcriptJsonPath: string;
  nextSegmentIndex: number;
}

interface VideoDimensions {
  width: number;
  height: number;
}

export class SessionStore {
  private readonly sessionGroups = new Map<string, SessionGroup>();

  prepareSession(request?: PrepareRecordingSessionRequest): PreparedRecordingSession {
    const existingSessionId = request?.existingSessionId;
    const group = existingSessionId ? this.sessionGroups.get(existingSessionId) ?? this.createSessionGroup() : this.createSessionGroup();
    const segmentIndex = group.nextSegmentIndex;
    group.nextSegmentIndex += 1;

    const directoryPath = join(group.rootDirectoryPath, "segments", String(segmentIndex).padStart(4, "0"));
    mkdirSync(directoryPath, { recursive: true });

    return {
      sessionId: group.sessionId,
      directoryPath,
      rootDirectoryPath: group.rootDirectoryPath,
      segmentIndex,
      audioPath: join(directoryPath, "audio.m4a"),
      videoPath: join(directoryPath, "video.mov"),
      transcriptPath: group.transcriptPath,
      transcriptJsonPath: group.transcriptJsonPath
    };
  }

  async finalizeSession(sessionId: string | undefined): Promise<void> {
    if (!sessionId) {
      return;
    }

    const group = this.sessionGroups.get(sessionId);
    if (!group) {
      return;
    }

    try {
      // A single user-visible recording can span several native capture segments
      // as the app switches between the main Meet tab and PiP/miniplayer.
      const segmentDirectories = Array.from({ length: group.nextSegmentIndex - 1 }, (_, index) =>
        join(group.rootDirectoryPath, "segments", String(index + 1).padStart(4, "0"))
      );
      const videoSegments = segmentDirectories
        .map((directoryPath) => join(directoryPath, "video.mov"))
        .filter((videoPath) => existsSync(videoPath));
      const audioSegments = segmentDirectories
        .map((directoryPath) => join(directoryPath, "audio.m4a"))
        .filter((audioPath) => existsSync(audioPath));
      const finalVideoPath = join(group.rootDirectoryPath, "video.mov");
      const finalAudioPath = join(group.rootDirectoryPath, "audio.m4a");
      const mergedVideoOnlyPath = join(group.rootDirectoryPath, "video-only.mov");

      await this.mergeVideoSegments(videoSegments, mergedVideoOnlyPath);
      await this.mergeAudioSegments(audioSegments, finalAudioPath);
      await this.muxAudioIntoVideo(mergedVideoOnlyPath, finalAudioPath, finalVideoPath);

      if (existsSync(mergedVideoOnlyPath)) {
        rmSync(mergedVideoOnlyPath);
      }
    } finally {
      this.sessionGroups.delete(sessionId);
    }
  }

  private createSessionGroup(): SessionGroup {
    const sessionId = new Date().toISOString().replaceAll(":", "-");
    const rootDirectoryPath = join(app.getAppPath(), "recordings", sessionId);
    mkdirSync(rootDirectoryPath, { recursive: true });

    const group: SessionGroup = {
      sessionId,
      rootDirectoryPath,
      transcriptPath: join(rootDirectoryPath, "transcript.txt"),
      transcriptJsonPath: join(rootDirectoryPath, "transcript.json"),
      nextSegmentIndex: 1
    };

    this.sessionGroups.set(sessionId, group);
    return group;
  }

  private async mergeVideoSegments(videoSegments: string[], outputPath: string): Promise<void> {
    if (videoSegments.length === 0) {
      return;
    }

    if (videoSegments.length === 1) {
      copyFileSync(videoSegments[0], outputPath);
      return;
    }

    // Normalise every segment to the first segment's dimensions before concat so
    // switches between full-window and PiP-sized captures still produce one file.
    const dimensions = await this.readVideoDimensions(videoSegments[0]);
    const filterParts = videoSegments.map((_, index) => {
      return `[${index}:v]scale=${dimensions.width}:${dimensions.height}:force_original_aspect_ratio=decrease,pad=${dimensions.width}:${dimensions.height}:(ow-iw)/2:(oh-ih)/2,setsar=1[v${index}]`;
    });
    const concatInputs = videoSegments.map((_, index) => `[v${index}]`).join("");
    const filterComplex = `${filterParts.join(";")};${concatInputs}concat=n=${videoSegments.length}:v=1:a=0[v]`;
    const args = [
      "-y",
      ...videoSegments.flatMap((videoPath) => ["-i", videoPath]),
      "-filter_complex",
      filterComplex,
      "-map",
      "[v]",
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      "-movflags",
      "+faststart",
      outputPath
    ];

    await execFileAsync(FFMPEG_PATH, args);
  }

  private async mergeAudioSegments(audioSegments: string[], outputPath: string): Promise<void> {
    if (audioSegments.length === 0) {
      return;
    }

    if (audioSegments.length === 1) {
      copyFileSync(audioSegments[0], outputPath);
      return;
    }

    const concatInputs = audioSegments.map((_, index) => `[${index}:a]`).join("");
    const filterComplex = `${concatInputs}concat=n=${audioSegments.length}:v=0:a=1[a]`;
    const args = [
      "-y",
      ...audioSegments.flatMap((audioPath) => ["-i", audioPath]),
      "-filter_complex",
      filterComplex,
      "-map",
      "[a]",
      "-c:a",
      "aac",
      outputPath
    ];

    await execFileAsync(FFMPEG_PATH, args);
  }

  private async muxAudioIntoVideo(videoPath: string, audioPath: string, outputPath: string): Promise<void> {
    if (!existsSync(videoPath)) {
      return;
    }

    if (!existsSync(audioPath)) {
      copyFileSync(videoPath, outputPath);
      return;
    }

    const args = [
      "-y",
      "-i",
      videoPath,
      "-i",
      audioPath,
      "-c:v",
      "copy",
      "-c:a",
      "aac",
      "-map",
      "0:v:0",
      "-map",
      "1:a:0",
      "-shortest",
      "-movflags",
      "+faststart",
      outputPath
    ];

    await execFileAsync(FFMPEG_PATH, args);
  }

  private async readVideoDimensions(videoPath: string): Promise<VideoDimensions> {
    const args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=width,height",
      "-of",
      "csv=p=0:s=x",
      videoPath
    ];
    const { stdout } = await execFileAsync("/opt/homebrew/bin/ffprobe", args);
    const [widthText, heightText] = stdout.trim().split("x");
    const width = Number(widthText);
    const height = Number(heightText);

    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      throw new Error(`Unable to determine video dimensions for ${videoPath}`);
    }

    return { width, height };
  }
}
