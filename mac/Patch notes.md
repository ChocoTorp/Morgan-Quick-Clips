# SimpleClips for Mac - Patch Notes

(The Mac and Windows builds version independently — Windows releases are in [windows/Patch notes.md](../windows/Patch%20notes.md).)

## V1.04 - June 9, 2026

**New**
- Choose your export speed. A toggle between the sliders and the size estimate offers "Fast export — about twice as fast" or "Best compression — slower, smallest file" (the default, same files as before). Fast mode trades a barely measurable amount of quality for roughly half the export time. It replaces V1.03's hardware/software encoder toggle: measured on real clips, the Mac's hardware encoder couldn't beat the software one on speed and produced noticeably worse quality for the size, so the choice that actually delivers is how hard the software encoder works.

**Better**
- Flipping the export speed toggle re-measures the size estimate automatically, so the number snaps to reality instead of waiting for "Harder estimate".
- When a format doesn't support a choice (GIF and a few legacy formats ignore export speed), only that option grays out and the usable one is selected for you.

## V1.03 - June 9, 2026

**New**
- An encoder toggle next to the size estimate: hardware (faster) vs software (smaller). Superseded in V1.04 by the export speed toggle.

**Faster**
- Exports now jump straight to the trim point instead of silently reading the whole file from the beginning. Exporting (or captioning) a section deep into a long video starts much faster, with no quality cost.

## V1.02 - June 9, 2026

**Catches up with Windows.** Everything the Windows build gained in its V1.01–V1.03 now works in the Mac app too:

**Faster**
- Scrubbing is now smooth and instant. After a clip loads, a small scrub-only preview is built quietly in the background; dragging the playhead or trim handles scrubs that instead of the full-resolution video, then snaps back to full quality the moment you let go.
- Dragging no longer queues up stale seeks: the picture follows your mouse instead of replaying the drag in slow motion. This helps even before the scrub preview is ready.

**Better**
- Much better file size estimate: accurate within moments of loading a clip (anchored to the clip's real content instead of a generic guess) and updating instantly as you move the quality, crop, resolution, FPS, and trim controls. A real measurement runs automatically when a clip loads, and the estimate stays calibrated to it from then on. The "Harder estimate" samples three spots spread across the clip, so one quiet or busy moment can't skew the measurement. The card shows which layer the number is on (rough / live / calibrated).
- "Saved to ..." status with the full file path after every export, plus a "Show in folder" button that opens it in Finder.
- A failed export no longer leaves a broken video file behind, and no longer reports "Saved" when something went wrong.
- Exporting the last clip of a set now shows feedback for that clip, instead of a confusing "Batch complete" message.
- You can now pick which microphone to record with, just like on Windows.
- The version number is shown next to the app name in the title bar.

**Changes**
- Exports default to 60fps for maximum compatibility; raise the FPS slider if you want a high-fps export. Recordings capture at up to 120fps on high refresh displays.

## V1.01 - June 5, 2026

- Original release.
