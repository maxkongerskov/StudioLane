# Studio Audio Lane

Native macOS prototype of a CleanShot X Studio feature: an **audio track under the video filmstrip**.

CleanShot X 5.0 is closed-source and signed. This is not a patch of their app. It is a working Studio-style editor that loads the Desktop recording and places a music lane beneath the video so the interaction can be demoed.

## What it does

- Opens `CleanShot 2026-09-04 at 1.12.12 PM.cleanshotvideo`
- Drops `Guten Morgen - Christian.wav` onto a new audio lane under the video
- Mixes music + original recording audio with separate volumes
- Play / scrub the timeline
- Replace by dropping another audio file
- Export a muxed MP4 to the Desktop

## Run

Dev wrap (`.build/StudioAudioLane.app`):

```bash
cd ~/Projects/StudioAudioLane
./scripts/launch.sh
```

Install into `/Applications/Studio Audio Lane.app` (Spotlight, Launchpad, Dock, Finder):

```bash
cd ~/Projects/StudioAudioLane
./scripts/install.sh
```

Or run the binary without wrapping:

```bash
swift run -c release
```
