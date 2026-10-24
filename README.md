# Reel

A minimal, free and open-source screen recorder for macOS, in the spirit of Loom.
Native Swift, macOS 26 and later. Shared videos live in **your own** Cloudflare account, inside its free tier.

Working name.

## What it does

**Record**
- Full screen, one window, a drawn area, or the camera alone; up to 4K.
- System audio and microphone; macOS voice isolation one click away.
- Camera bubble in four shapes (round, squircle, portrait, landscape), thrown into a corner with momentum.
- macOS camera effects: portrait blur, backgrounds, studio light.
- Pause, Live Rewind (drop the last 5 seconds and keep going), drawing on screen, blur boxes over sensitive areas.
- Notifications and desktop icons stay out of the video. Click highlighting.
- Teleprompter under the bubble, never recorded; dictate rough notes and the AI turns them into talking points.
- ⌥⇧R starts and stops from anywhere.

**Edit** (non-destructive)
- Timeline of video frames with trim handles; strike words in the transcript to cut them.
- Remove hesitations and silences, found from the audio itself.
- Text, arrow and box annotations; burned-in captions; a backdrop around the screen; automatic voice level.
- Custom thumbnail and an animated GIF preview.

**AI** — on the Mac with Apple Intelligence (default), or with Claude and your own API key
- Title, summary, chapters, tasks and a suggested call to action.
- A video becomes a procedure (SOP), a ticket, or a message.
- **Agent mode**: every click is captured with the app, window, browser address, a marked screenshot and the clicked text read on-device, then merged with the narration into a step-by-step plan. Copy it as a prompt or open it in Claude Code.
- **MCP**: `reel-mcp` lets agents list your videos and read transcripts, summaries and agent plans.

**Share**
- A link copied the moment you stop; private, unlisted, public or password-protected.
- The share page shows only your name or logo and your player color — never Reel's.
- Chapters, captions, clickable links in the video, timestamped comments, reactions, and who watched how far.

## Install the sharing server

The app does it for you on first launch: create a free Cloudflare account, enable R2, create an API token with
*Workers Scripts: Edit*, *Workers R2 Storage: Edit*, *D1: Edit* and *Account Settings: Read*, and paste it.
Reel creates the bucket, the database and the server, then gives you its address.

Cloudflare has no spending limit, so the server enforces one: it refuses uploads and plays before the free tier
ends (9 GB stored, 900,000 writes and 9 million reads a month). Your account never pays.

To deploy by hand instead: see `cloud/` (`wrangler.jsonc`, `migrations/`, `test/smoke.sh`).

## Use your library from Claude Code

```sh
claude mcp add reel -- /Applications/Reel.app/Contents/MacOS/reel-mcp
```

## Build

```sh
./scripts/build-app.sh       # builds and signs dist/Reel.app
./scripts/bundle-worker.sh   # after changing cloud/: refreshes the server bundle the app installs
cd App && swift test         # unit tests; set REEL_SAMPLE_VIDEO=/path/to/video.mp4 for media tests
```

The app is signed with the first valid code signing identity on the Mac, so macOS keeps its
permissions across rebuilds (set `REEL_SIGN_IDENTITY` to choose another one).

Development helpers: `--demo panel|library|settings|onboarding|recording`, `--demo editor <video>`,
`--selftest <report.json>`, `--transcribe <video> <report.json> [--ai]`.

## Layout

```
App/Sources/ReelKit   engine: capture, segments, composition, transcription, audio analysis, AI, cloud client and setup
App/Sources/Reel      menu bar app (art direction « Halo », tokens in Theme.swift)
App/Sources/reel-mcp  MCP server for agents
cloud/                sharing server: Cloudflare Worker + R2 + D1
```

## License

MIT
