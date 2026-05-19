# Shanks

> **Fan-work notice.** This is a free, non-commercial, fan-made macOS pet. The character likeness and design are from One Piece, © Eiichiro Oda / Shueisha / Toei Animation — used here only as personal fan art. No affiliation with or endorsement by the rights holders. If you are a rights holder and would like the art removed, please open a GitHub issue or contact the maintainer and the art will be taken down promptly.

<p align="center">
  <img src="Clawd/ShanksIcon.png" width="160" alt="Shanks" />
</p>

A chibi pirate captain who lives on your macOS dock, reacts to Claude Code activity, and reports your token spend. Built on top of [Mewtwo](https://github.com/catwomaniya/Mewtwo---Claude-pet-bot) — same engine, reskinned with a red-haired pirate captain and a full-pirate-accent personality.

## features

- 🏴‍☠️ pixel art pirate walks along your dock and reacts to Claude Code activity
- tap to pet — emotions escalate the more you tap (happy → love → wink → surprised → scared → smug → angry → dead)
- listens for Claude Code hook events on `localhost:7772` (approval requests, input needed, task complete)
- system notifications when Claude needs your approval, input, or finishes a task
- **Check Usage** menu item shows real 5-hour & 7-day percentages from claude.ai's API **plus** raw token counts and turn counts from your local transcripts
- pirate-accent comment lines every 30 min ("yarr the cap'n returns, did ye miss me 😤")
- auto-sleeps when you max out your quota; auto-wakes when it resets
- works in fullscreen spaces
- launch on login

## requirements

- macOS 13+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- Swift 5.9+ (ships with Xcode Command Line Tools)

## install

Build from source:

```bash
git clone https://github.com/unknownking07/shanks-claude-pet.git
cd shanks-claude-pet
./scripts/build-local.sh
open /Applications/Shanks.app
```

The build script:
1. Builds the Swift release binary
2. Assembles `Shanks.app` with `Info.plist`, resources, and ad-hoc signature
3. Installs to `/Applications/Shanks.app`

## sign-in & usage

Click the Shanks icon in your menu bar:

- **Sign In to Claude…** — opens `claude.ai/login` in your default browser (Chrome / Brave / Safari) where Google OAuth and any other sign-in method works normally. Sign in there, then:
  1. Open DevTools (`⌥⌘I` in Chrome/Brave)
  2. Application → Cookies → `https://claude.ai`
  3. Copy the **Value** of the `sessionKey` cookie
  4. Paste it into the dialog Shanks popped up → Sign In
  
  Shanks injects the cookie into its WebKit store and you're authenticated for ~30 days. (The sessionKey is HttpOnly so the DevTools step is necessary — `document.cookie` from the console can't see it.)

Then:

- **Check Usage** shows a bubble like:
  ```
  plunder report cap'n
  5h rations: 23% spent · 4.2M tokens · 28 turns
  7d rations: 11% spent · 18M tokens · 142 turns
  ```
  Percentages come from claude.ai's API. Token counts and turns come from scanning `~/.claude/projects/**/*.jsonl`.
- **Sign Out Claude** clears the WebKit cookie store + cached org ID.
- **Wake Up Shanks** force-wakes him if he's sleeping through a quota cooldown.

## how activity tracking works

Shanks installs Claude Code hooks into `~/.claude/settings.json` and runs a tiny HTTP server on `localhost:7772`. When Claude Code emits a hook event, the curl command in the hook posts to Shanks. He reacts — surprised face + sound for approval requests, happy + sparkle for completed tasks, etc.

Hook events handled:
- `Notification` — Claude needs your input
- `PermissionRequest` — Claude is asking to use a tool
- `PostToolUse` — Claude finished a tool call
- `Stop` — a Claude session ended

Multiple Mewtwo-family pets can coexist if they listen on different ports (Mewtwo uses 7771, Shanks 7772). Both will react to every Claude event.

## customizing the art

Sprites are PNG files under `Clawd/`:

| File | Purpose | Dimensions |
| --- | --- | --- |
| `ShanksSheet.png` | 9-frame horizontal sheet: idle, walkA, walkB, blink, sad, happy, surprised, smug, sleepy | 2880×320 |
| `ShanksAsleep1.png` | Sleeping frame 1 | 320×320 |
| `ShanksAsleep2.png` | Sleeping frame 2 (alternates with 1) | 320×320 |
| `ShanksIcon.png` | Menu bar icon | 320×320 |

Drop in your own and re-run `./scripts/build-local.sh`. No code changes needed.

Two helper scripts for sprite generation are included:
- **`scripts/slice-ref.py`** — slice a 2172×724-ish reference image (white outer canvas, characters on black strip) into 9 frames, flood-key the background, and assemble the sheet. Reads from `scripts/shanks-source.png` or `~/Downloads/shanks.png` (or `$SHANKS_REF` env var).
- **`scripts/gen-sprites.py`** — hand-coded 32×32 pixel art generator used during early iteration. Useful as a fallback or starting point.

## credits

- **Upstream codebase:** [catwomaniya/Mewtwo---Claude-pet-bot](https://github.com/catwomaniya/Mewtwo---Claude-pet-bot) — MIT licensed. All the pet-walking, hook server, WKWebView claude.ai usage check, and local token tracker machinery is from there.
- **Shanks character:** Eiichiro Oda / Shueisha / Toei Animation (One Piece). The sprite art shipped in this repo is fan-made pixel art derived from that design. Personal, non-commercial use only. See the fan-work notice at the top.

## takedown

If you represent a rights holder and want the character art removed, [open an issue](https://github.com/unknownking07/shanks-claude-pet/issues/new) or contact the maintainer directly. The sprite PNGs under `Clawd/` will be replaced with original placeholder art within 48 hours of receiving a request.

## license

MIT. The original Mewtwo copyright is preserved in [`LICENSE`](LICENSE); my fork's additions are also MIT.

## privacy

Everything runs locally. Hook events go to `localhost:7772` only. The browser sign-in window persists cookies in WKWebView's per-app data store (sandboxed to `com.shanks.app`, not shared with Safari or other browsers).
