import { BrowserWindow, app, ipcMain, session, shell, systemPreferences } from "electron";
import { join } from "node:path";

import { NativeRecorderManager } from "./native-recorder";
import { SessionStore } from "./session-store";
import { IPC_CHANNELS } from "../shared/ipc";
import { ChromeTabDetector } from "./providers/chrome-tab-detector";
import { GoogleMeetAdapter } from "./providers/google-meet-adapter";
import { GoogleMeetTranscriptRecorder } from "./google-meet-transcript-recorder";
import { ProviderManager } from "./providers/provider-manager";
import { ZoomAppAdapter } from "./providers/zoom-app-adapter";
import { ZoomBrowserAdapter } from "./providers/zoom-browser-adapter";

const sessionStore = new SessionStore();
const nativeRecorder = new NativeRecorderManager();
const chromeTabs = new ChromeTabDetector();
const transcriptRecorder = new GoogleMeetTranscriptRecorder(chromeTabs);
const providerManager = new ProviderManager([
  new ZoomAppAdapter(() => nativeRecorder.listSources()),
  new GoogleMeetAdapter(chromeTabs),
  new ZoomBrowserAdapter(chromeTabs)
]);
const allowedPermissions = new Set(["media", "display-capture"]);

let mainWindow: BrowserWindow | null = null;
let isQuitting = false;
let activeRecordingSessionId: string | null = null;

function createMainWindow(): BrowserWindow {
  const window = new BrowserWindow({
    width: 980,
    height: 720,
    title: "Botless Notetaker",
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      preload: join(app.getAppPath(), "dist", "preload", "preload.js")
    }
  });

  window.webContents.on("preload-error", (_event, preloadPath, error) => {
    console.error(`[preload] Failed to load ${preloadPath}`);
    console.error(error);
  });

  window.webContents.on("console-message", (event) => {
    console.log(`[renderer:${event.level}] ${event.message} (${event.sourceId}:${event.lineNumber})`);
  });

  void window.loadFile(join(app.getAppPath(), "dist", "renderer", "index.html"));
  window.on("closed", () => {
    mainWindow = null;
  });

  return window;
}

function registerIpcHandlers(): void {
  ipcMain.handle(IPC_CHANNELS.detectMeeting, async () => {
    return providerManager.detectMeeting();
  });

  ipcMain.handle(IPC_CHANNELS.getPermissions, async () => {
    return {
      platform: process.platform,
      microphone: systemPreferences.getMediaAccessStatus("microphone"),
      screen: systemPreferences.getMediaAccessStatus("screen"),
      chromeAutomation: await chromeTabs.getAutomationStatus()
    };
  });

  ipcMain.handle(IPC_CHANNELS.getRecorderState, () => {
    return nativeRecorder.getState();
  });

  ipcMain.handle(IPC_CHANNELS.listNativeCaptureSources, async () => {
    return nativeRecorder.listSources();
  });

  ipcMain.handle(IPC_CHANNELS.prepareBrowserMeetingSurface, async (_event, request) => {
    if (request.provider === "google-meet") {
      return chromeTabs.requestGoogleMeetPopup(request.meetingUrl);
    }

    return {
      ok: true,
      message: "No browser surface preparation required"
    };
  });

  ipcMain.handle(IPC_CHANNELS.prepareSession, (_event, request) => {
    // Session preparation happens before every native segment start, but the
    // same logical session ID can be reused across several surface switches.
    const session = sessionStore.prepareSession(request);
    activeRecordingSessionId = session.sessionId;
    console.log(`[recording] Prepared session ${session.sessionId} segment=${session.segmentIndex} -> ${session.directoryPath}`);
    return session;
  });

  ipcMain.handle(IPC_CHANNELS.requestMicrophoneAccess, async () => {
    return systemPreferences.askForMediaAccess("microphone");
  });

  ipcMain.handle(IPC_CHANNELS.startNativeRecording, async (_event, request) => {
    const state = await nativeRecorder.startRecording(request);
    activeRecordingSessionId = request.session.sessionId;

    if (request.meetingUrl && request.meetingUrl.includes("meet.google.com/")) {
      await transcriptRecorder.start({
        meetingUrl: request.meetingUrl,
        transcriptPath: request.session.transcriptPath,
        transcriptJsonPath: request.session.transcriptJsonPath
      });
      console.log(`[transcript] Started Google Meet transcript capture -> ${request.session.transcriptPath}`);
    }

    console.log(`[recording] Native recording starting for ${request.session.sessionId}`);
    return state;
  });

  ipcMain.handle(IPC_CHANNELS.stopNativeRecording, async (_event, request) => {
    const finalizeSession = request?.finalizeSession !== false;

    if (finalizeSession) {
      await transcriptRecorder.stop();
    }

    const state = await nativeRecorder.stopRecording();

    if (finalizeSession) {
      await sessionStore.finalizeSession(request?.sessionId ?? activeRecordingSessionId ?? undefined);
      activeRecordingSessionId = null;
      console.log("[recording] Native recording stopped and session finalized");
    } else {
      console.log("[recording] Native recording segment stopped");
    }

    return state;
  });

  ipcMain.handle(IPC_CHANNELS.openSystemSettings, async (_event, target: "microphone" | "screen" | "automation") => {
    const url = systemSettingsUrl(target);
    return shell.openExternal(url);
  });

  ipcMain.on(IPC_CHANNELS.log, (_event, message: string) => {
    console.log(`[renderer] ${message}`);
  });
}

function systemSettingsUrl(target: "microphone" | "screen" | "automation"): string {
  switch (target) {
    case "microphone":
      return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone";
    case "screen":
      return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";
    case "automation":
      return "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation";
  }
}

app.whenReady().then(() => {
  session.defaultSession.setPermissionCheckHandler((_webContents, permission) => {
    return allowedPermissions.has(permission);
  });

  session.defaultSession.setPermissionRequestHandler((_webContents, permission, callback) => {
    callback(allowedPermissions.has(permission));
  });

  registerIpcHandlers();
  mainWindow = createMainWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      mainWindow = createMainWindow();
    }
  });
});

app.on("before-quit", (event) => {
  if (isQuitting) {
    return;
  }

  event.preventDefault();
  isQuitting = true;

  void transcriptRecorder.stop()
    .catch((error) => {
      console.error(`[transcript] Failed to stop transcript recorder during quit: ${String(error)}`);
    })
    .finally(() => {
      void nativeRecorder.stopRecording()
        .then(async () => {
          await sessionStore.finalizeSession(activeRecordingSessionId ?? undefined);
          activeRecordingSessionId = null;
        })
        .finally(() => {
          app.quit();
        });
    });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});
