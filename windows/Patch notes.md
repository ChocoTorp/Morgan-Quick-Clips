# SimpleClips for Windows - Patch Notes

(The Mac and Windows builds version independently — Mac releases are in [mac/Patch notes.md](../mac/Patch%20notes.md).)

## V1.03 - June 9, 2026

**Faster**
- Scrubbing is now smooth and instant. After a clip loads, a small scrub-only preview is built quietly in the background; while you drag the playhead or trim handles, the app scrubs that instead of the full-resolution video, then snaps back to full quality the moment you let go. You never see it except mid-drag.
- Dragging no longer queues up stale seeks: the picture follows your mouse instead of replaying the drag in slow motion. This helps even before the scrub preview is ready.

## V1.02 - June 9, 2026

**Faster**
- Recordings are ready almost instantly after you hit Stop. The recorder now captures H.264 using your GPU's hardware encoder (the same approach the Mac version uses), so finishing a recording is a quick repackage instead of a minutes-long re-encode. A 5 minute recording that used to take over 2 minutes to process now takes about a second. Region recordings still do one encode pass for the crop, but it's much faster too.

**Better**
- Recording quality is higher: the recorder now uses a proper bitrate for screen resolution instead of its very low default.
- The size estimate box is a bit wider and its text wraps cleanly between items instead of mid-phrase.

## V1.01 - June 9, 2026

**Fixes**
- Exported MP4s now play everywhere. Recording on high refresh rate monitors (120Hz+) produced files that Windows' built-in video players refused to open.
- A failed export no longer leaves a broken video file behind, and no longer reports "Saved" when something went wrong.
- If finishing a recording fails, the raw recording is kept instead of being lost.
- Exporting the last clip of a set now shows feedback for that clip, instead of a confusing "Batch complete" message.

**New**
- Encoding progress bar after you stop a recording. Long recordings used to sit silent for minutes while they were processed.
- "Saved to ..." status with the full file path after every export, plus a "Show in folder" button that opens it in Explorer.
- Much better file size estimate: accurate within moments of loading a clip (anchored to the clip's real content instead of a generic guess) and updating instantly as you move the quality, crop, resolution, FPS, and trim controls.
- The version number is shown next to the app name in the title bar, and build files are now named with the version (SimpleClips-1.01-portable.exe).

**Changes**
- Recordings capture at up to 120fps on high refresh displays (lower displays record at their own rate). Exports default to 60fps for maximum compatibility; raise the FPS slider if you want a high-fps export.
- The "Harder estimate" now samples three spots spread across the clip, so one quiet or busy moment can't skew the measurement.
