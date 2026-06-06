// Single source of truth for encode settings, shared by export AND the estimator
// so the estimate reflects exactly what export will do.
//
// Faithful port of plan() from the macOS app (Sources/ClipEditor.swift).
//   format: "MP4" | "GIF" | "WEBM" | "MPG" | "WMV" | ... (H.264 family otherwise)
//   q:      continuous fidelity -> optimization, 0..1
//           (0 = maximum fidelity, 1 = maximum optimization; the slider drives this)
//   crop:   the leading -vf filtergraph (crop[,scale]) already built from the UI
//   fps:    target fps, or null to keep the source rate
// Returns { vf, codec }: the -vf filtergraph and the trailing codec args (as a string).
//
// NOTE: the quality slider only changes compression — it NEVER alters resolution.
// Output size is controlled entirely by the crop + output-size fields (baked into `crop`).
function plan(format, q, crop, fps) {
  const rate = fps != null ? ` -r ${fps}` : '';
  const qq = Math.min(Math.max(q, 0), 1);
  switch (format) {
    case 'GIF': {
      const gfps = Math.round(20 - qq * 8); // 20 -> 12 fps
      let pal, use;
      if (qq < 0.34) {
        pal = 'palettegen=stats_mode=full';
        use = 'paletteuse=dither=sierra2_4a';
      } else if (qq < 0.67) {
        pal = 'palettegen=stats_mode=diff';
        use = 'paletteuse=dither=bayer';
      } else {
        pal = 'palettegen=max_colors=128:stats_mode=diff';
        use = 'paletteuse=dither=bayer:bayer_scale=2';
      }
      const vf = `${crop},fps=${fps != null ? fps : gfps},split[a][b];[a]${pal}[p];[b][p]${use}`;
      return { vf, codec: '' };
    }
    case 'WEBM': {
      const crf = Math.round(18 + qq * 22); // 18 -> 40
      const ab = Math.round(192 - qq * 96); // 192 -> 96 kbps
      const extra = qq > 0.67 ? '-row-mt 1 -deadline good -cpu-used 3' : '-row-mt 1';
      return {
        vf: crop,
        codec: `-c:v libvpx-vp9 -crf ${crf} -b:v 0 ${extra} -pix_fmt yuv420p${rate} -c:a libopus -b:a ${ab}k`,
      };
    }
    case 'MPG': {
      // MPEG-1/2 program stream
      const qv = Math.round(2 + qq * 5); // 2 -> 7
      return { vf: crop, codec: `-c:v mpeg2video -q:v ${qv}${rate} -c:a mp2 -b:a 192k` };
    }
    case 'WMV': {
      const qv = Math.round(2 + qq * 4); // 2 -> 6
      return { vf: crop, codec: `-c:v wmv2 -q:v ${qv}${rate} -c:a wmav2 -b:a 192k` };
    }
    default: {
      // H.264/AAC family of containers: MP4, MOV, M4V, MKV, AVI, TS, FLV, F4V, 3GP
      const crf = Math.round(14 + qq * 16); // 14 -> 30
      const preset = qq < 0.34 ? 'slow' : qq < 0.67 ? 'medium' : 'slower';
      const ab = Math.round(256 - qq * 160); // 256 -> 96 kbps
      const profile = format === '3GP' ? ' -profile:v baseline -level 3.1' : '';
      const fast = ['MP4', 'MOV', 'M4V'].includes(format) ? ' -movflags +faststart' : '';
      return {
        vf: crop,
        codec: `-c:v libx264 -crf ${crf} -preset ${preset}${profile} -pix_fmt yuv420p${rate} -c:a aac -b:a ${ab}k${fast}`,
      };
    }
  }
}

// Split a plan() codec string ("-c:v libx264 -crf 18 ...") into argv tokens.
// Mirrors args() in the Swift app: whitespace split, empties dropped (no shell).
function splitArgs(s) {
  return s.trim().length ? s.trim().split(/\s+/) : [];
}

module.exports = { plan, splitArgs };
