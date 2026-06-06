// SimpleClips media engine — cross-platform (Windows + macOS) port of the media
// pipeline from the macOS app's Sources/ClipEditor.swift. Pure Node + ffmpeg/whisper;
// no Electron or platform UI dependencies, so it can run headless (see tools/engine-cli.js).
module.exports = {
  ...require('./tools'),
  ...require('./util'),
  ...require('./plan'),
  ...require('./ffmpeg'),
  ...require('./probe'),
  ...require('./estimate'),
  ...require('./proxy'),
  ...require('./captions'),
  ...require('./export'),
};
