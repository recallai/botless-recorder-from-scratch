# Botless Notetaker

This is a local macOS meeting recorder for Google Meet built with Electron and a native Swift capture helper.

If you want the full project write-up, read the blog post on how to [record meetings without bots](https://www.recall.ai/blog/how-i-built-a-botless-meeting-recorder-from-scratch).

## What it does

- Detects an active Google Meet in Google Chrome
- Records video through ScreenCaptureKit
- Records system audio and microphone audio
- Uses Google Meet captions for a live transcript
- Switches between the main Meet window and the Meet Picture-In-Picture/miniplayer when needed
- Merges segment recordings into one final `video.mov` and one final `audio.m4a`

## What you need

Use this on:

- macOS
- Apple Silicon Mac
- Google Chrome
- Node.js 20+ and npm
- Xcode command line tools with `swiftc`
- `ffmpeg`
- `ffprobe`

Before you start, make sure these commands work:

```bash
node -v
npm -v
swiftc --version
ffmpeg -version
ffprobe -version
```

If `ffmpeg` or `ffprobe` are missing and you use Homebrew, install them with:

```bash
brew install ffmpeg
```

## Install

From the project root, run:

```bash
npm install
```

## Build

Build the Electron app and both native helpers:

```bash
npm run build
```

This creates:

- the Electron app output in `dist/`
- the native helpers in `dist/native/`

## Run

Start the app with:

```bash
npm start
```

The window should open and begin watching for supported meetings.

## First-time macOS permissions

The recorder needs these permissions:

1. Screen Recording
2. Microphone
3. Chrome automation

When the app asks, allow the permissions.

If Chrome automation does not work, open Chrome and enable:

`View > Developer > Allow JavaScript from Apple Events`

If that setting is off, transcript capture and some Google Meet automation paths will fail.

## How to use it

1. Open Google Chrome.
2. Join a Google Meet.
3. Start this app.
4. Wait for the app to detect the meeting.
5. Keep using your computer normally.
6. When you are done, leave the meeting or stop recording in the app.

The app writes recordings to the `recordings/` folder.

Each completed recording session should contain:

- `video.mov`
- `audio.m4a`
- `transcript.txt`
- `transcript.json`

During tab or Picture-in-Picture (PiP) switches, the app may also create temporary segment files under:

- `recordings/<session>/segments/`

Those are expected. On final stop, the app merges those segments into the one final `video.mov` and one final `audio.m4a` in the root session folder.

## Important limitations

- This project is macOS-first.
- The main path is Google Meet in Google Chrome.
- It depends on Chrome automation for transcript capture and some Meet-specific behaviors.
- PiP/miniplayer switching works by changing capture surfaces, so the app records in segments internally and merges them afterward.
- Zoom support was explored in the codebase but is not the main path this repo was hardened around.

## Troubleshooting

If the app does not detect your meeting:

- Make sure the meeting is in Google Chrome
- Make sure the Meet tab is still open
- Make sure Chrome automation is allowed

If the app detects the meeting but does not record:

- Check Screen Recording permission in macOS System Settings
- Check Microphone permission in macOS System Settings
- Run `npm run build` again and then retry

If transcripts are missing:

- Make sure Chrome automation is working
- Make sure Meet captions can be enabled

If build fails:

- check that `swiftc` is installed
- check that `ffmpeg` and `ffprobe` are installed
- run `npm install` again

## Useful commands

Build everything:

```bash
npm run build
```

Start the app:

```bash
npm start
```

Type-check only:

```bash
npm run check
```

## Other desktop recording resources
If you want to learn more about [how to access system audio](https://www.recall.ai/blog/how-to-access-to-system-audio) we've also written a blog on that with demos and if you're just interested in [macOS screen capture APIs](https://www.recall.ai/blog/macos-screencapture-api) there is a guide on all of the APIs to record on macOS. For those interested in Granola.ai, we've also put out a blog on open source [Granola.ai alternatives](https://www.recall.ai/blog/granola-ai-alternatives) and a tutorial on how to [build a meeting notetaker like granola](https://www.recall.ai/blog/how-to-build-a-desktop-recording-app). Finally, if you are interested in [how to build a desktop app](https://www.recall.ai/blog/how-to-build-a-desktop-recording-app) using Recall.ai we've written a tutorial on that and built an app that you can test out or fork.
