# Improvement log

## Verified

- Empty launch is calm: “Drop media here”, disabled Export, two lanes.
- Dropping a file on the preview used to show the accept cursor and import nothing. The filmstrip view was taking the drop. It now reads the file URLs. Checked by dropping `recording.mp4` (and `voice.aiff`, which was also selected) onto an empty preview: the picture and filmstrip appeared, and the voice clip landed on the audio lane. Commit `3099fc4`.
- At 1568×780 the clip actions and lower sliders were cut off under the timeline. Mute, Replace, Fit to Video, and Delete clip now sit in a footer, and fade in, fade out, and length are visible. Mute toggles to Unmute. Commit `707998d`.
- Reopening threw the autosave away because the loader checked the empty live timeline. Quit and relaunch now brings the recording and the voice clip back, with their lengths. Commit `d382a3b`.
- Command-O opens the media panel and can place a video. Open media still works after the drop fix.
- Playhead is stored in the project and restored. A file marked at 3.5s reopened at 00:03.5 and the autosave kept it. Commit `a9b118c`. Mute toggles to Unmute and the clip reads Muted.

## Decisions

- The recording’s sound already has its own track volume, clip gain, and audio mix. Left that structure.
- Removed the duplicate inspector chips (Add media, Fill from Files, Replace) so the sliders fit. Those actions remain in the menus, and Replace remains on the selected clip. Playlist stays as the layout toggle.

## Next

- Edit ▸ Undo stays disabled after an edit. Mute does record a history step (`toggleMuteSelectedAudio` calls `pushHistory` directly). The window undo manager cannot take that step: `registerUndo` never returns, and assigning `undoManager` aborts the app. A private undo manager accepts the registration, and it is not the menu the menu bar shows. Checked 26 Sep 2026.
- The test project in autosave was wiped when a crash dialog opened an empty window. Fixtures are still in `/tmp/sal-fixtures`. Rebuild the edit from those before the mix check.
- Track volume changes do not push undo history. Not yet confirmed in the app.
- A file that is not media is still treated as video. Not yet dropped.
- Still to walk: trim, move, split, fade, the two volumes, mute in the mix, undo/redo of picture and sound, save/reopen of a non-zero playhead, export played outside the app, zoom and scrub, add a lane, delete back to empty, 1100×620, and the keyboard equivalents.
- Replace the voice clip with `music.wav` before the mix check. Fixtures are in `/tmp/sal-fixtures`.
- README describes the studio as it stands.
- Original autosave is in `/tmp/studio-audio-lane-protect/autosave.json`. Put it back when the session is done. Do not use `scripts/install.sh`.
