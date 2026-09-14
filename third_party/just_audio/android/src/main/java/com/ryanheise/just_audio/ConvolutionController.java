package com.ryanheise.just_audio;

import androidx.annotation.Nullable;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/**
 * Shared impulse-response state for {@link ConvolutionAudioProcessor}.
 *
 * <p>Supports mono/stereo IRS and EchoMusic-style 4-channel binaural WAV
 * (channel order {@code LL, LR, RL, RR}).
 */
public final class ConvolutionController {
  private static final ConvolutionController INSTANCE = new ConvolutionController();

  /** Max impulse length kept per path (samples). Longer IRs are truncated. */
  public static final int MAX_IR_SAMPLES = 49152;

  private volatile boolean enabled;
  private volatile float wet = 0.85f;
  private volatile float dry = 0.35f;
  private volatile float outputGain = 1.0f;

  /**
   * 360 orbit: slowly pans the wet image L↔R around the head.
   * Static IR alone cannot "run" left/right — orbit supplies the motion.
   */
  private volatile boolean orbitEnabled;
  private volatile float orbitHz = 0.12f;
  private volatile float orbitDepth = 0.9f;

  /** True when IR is 4-channel binaural matrix. */
  private volatile boolean binaural;

  @Nullable private volatile float[] irLL;
  @Nullable private volatile float[] irLR;
  @Nullable private volatile float[] irRL;
  @Nullable private volatile float[] irRR;
  private volatile int irLength;
  private volatile int irChannels = 1;
  /** Native sample rate of the loaded IR (Hz). WAV reports this; raw IRS assume 44100. */
  private volatile int irSampleRate = 44100;
  private volatile String loadedPath = "";
  /** Cached resampled paths for the last requested playback rate. */
  private int cachedPlayRate = -1;
  @Nullable private float[] cachedLL;
  @Nullable private float[] cachedLR;
  @Nullable private float[] cachedRL;
  @Nullable private float[] cachedRR;
  private int cachedLength;

  private ConvolutionController() {}

  public static ConvolutionController getInstance() {
    return INSTANCE;
  }

  public boolean isEnabled() {
    return enabled && irLength > 0;
  }

  public boolean hasImpulse() {
    return irLength > 0;
  }

  public boolean isBinaural() {
    return binaural;
  }

  public void setEnabled(boolean enabled) {
    this.enabled = enabled;
  }

  public void setMix(float wet, float dry) {
    this.wet = clamp01(wet);
    this.dry = clamp01(dry);
  }

  public void setOutputGain(float gain) {
    this.outputGain = Math.max(0.05f, Math.min(gain, 4.0f));
  }

  public void setOrbit(boolean enabled, float hz, float depth) {
    this.orbitEnabled = enabled;
    this.orbitHz = Math.max(0.02f, Math.min(hz, 1.0f));
    this.orbitDepth = clamp01(depth);
  }

  public boolean isOrbitEnabled() {
    return orbitEnabled;
  }

  public float getOrbitHz() {
    return orbitHz;
  }

  public float getOrbitDepth() {
    return orbitDepth;
  }

  public float getWet() {
    return wet;
  }

  public float getDry() {
    return dry;
  }

  public float getOutputGain() {
    return outputGain;
  }

  public int getIrLength() {
    return irLength;
  }

  public int getIrChannels() {
    return irChannels;
  }

  public int getIrSampleRate() {
    return irSampleRate;
  }

  public String getLoadedPath() {
    return loadedPath;
  }

  /**
   * Returns IR paths resampled to {@code playRateHz}. All four arrays share the same length.
   * Order: LL, LR, RL, RR.
   */
  public synchronized float[][] getPathsForRate(int playRateHz) {
    if (irLL == null || irLength <= 0) {
      return new float[0][];
    }
    int rate = playRateHz > 0 ? playRateHz : irSampleRate;
    if (rate == cachedPlayRate && cachedLL != null) {
      return new float[][] {cachedLL, cachedLR, cachedRL, cachedRR};
    }
    float[] ll = irLL;
    float[] lr = irLR != null ? irLR : zerosLike(irLL);
    float[] rl = irRL != null ? irRL : zerosLike(irLL);
    float[] rr = irRR != null ? irRR : irLL;
    if (rate != irSampleRate && irSampleRate > 0) {
      ll = resampleLinear(ll, irSampleRate, rate);
      lr = resampleLinear(lr, irSampleRate, rate);
      rl = resampleLinear(rl, irSampleRate, rate);
      rr = resampleLinear(rr, irSampleRate, rate);
    }
    cachedPlayRate = rate;
    cachedLL = ll;
    cachedLR = lr;
    cachedRL = rl;
    cachedRR = rr;
    cachedLength = ll.length;
    return new float[][] {ll, lr, rl, rr};
  }

  public synchronized int getLengthForRate(int playRateHz) {
    getPathsForRate(playRateHz);
    return cachedLength;
  }

  @Nullable
  public float[] getIrLL() {
    return irLL;
  }

  @Nullable
  public float[] getIrLR() {
    return irLR;
  }

  @Nullable
  public float[] getIrRL() {
    return irRL;
  }

  @Nullable
  public float[] getIrRR() {
    return irRR;
  }

  /** Stereo-compatible alias: left path ({@code LL}). */
  @Nullable
  public float[] getIrL() {
    return irLL;
  }

  /** Stereo-compatible alias: right path ({@code RR}). */
  @Nullable
  public float[] getIrR() {
    return irRR;
  }

  public synchronized void clear() {
    irLL = null;
    irLR = null;
    irRL = null;
    irRR = null;
    irLength = 0;
    irChannels = 1;
    irSampleRate = 44100;
    binaural = false;
    orbitEnabled = false;
    loadedPath = "";
    enabled = false;
    clearRateCache();
  }

  private void clearRateCache() {
    cachedPlayRate = -1;
    cachedLL = null;
    cachedLR = null;
    cachedRL = null;
    cachedRR = null;
    cachedLength = 0;
  }

  public synchronized void loadFromFile(String path) throws IOException {
    byte[] data = readAll(new File(path));
    loadFromBytes(data, path);
  }

  public synchronized void loadFromBytes(byte[] data, String label) {
    if (data == null || data.length < 4) {
      clear();
      throw new IllegalArgumentException("empty impulse data");
    }
    ParsedIr parsed;
    if (data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F') {
      parsed = parseWav(data);
    } else {
      parsed = parseRawIrs(data);
    }
    // Joint peak across all paths — per-channel normalize destroys ILD / surround cues.
    normalizeJointPeak(parsed.ll, parsed.lr, parsed.rl, parsed.rr, 0.85f);

    irLL = parsed.ll;
    irLR = parsed.lr;
    irRL = parsed.rl;
    irRR = parsed.rr != null ? parsed.rr : parsed.ll;
    if (!parsed.binaural) {
      // Stereo/mono: independent L/R convolution (no cross terms).
      irLR = zerosLike(irLL);
      irRL = zerosLike(irLL);
    }
    irLength = parsed.ll.length;
    irChannels = parsed.channels;
    irSampleRate = parsed.sampleRate > 0 ? parsed.sampleRate : 44100;
    binaural = parsed.binaural;
    loadedPath = label == null ? "" : label;
    clearRateCache();

    // Safer mix: high wet + dry caused clipping that sounded like noise.
    String name = label == null ? "" : label;
    boolean orbitPreset = isOrbitPresetName(name);
    if (orbitPreset) {
      // 清晰优先：保留足够干声；环绕只做轻量 L/R 摆动，避免糊成一团。
      wet = 0.55f;
      dry = 0.55f;
      outputGain = 0.92f;
      float hz = 0.08f;
      if (name.contains("深空")) {
        hz = 0.055f;
      } else if (name.contains("近场")) {
        hz = 0.10f;
      } else if (name.contains("舞台")) {
        hz = 0.07f;
      } else if (name.contains("宽景") || name.contains("8D")) {
        hz = 0.085f;
      }
      orbitEnabled = true;
      orbitHz = hz;
      // depth 过深会把卷积结果压成单声道 mid，人声/细节会「听不清」
      orbitDepth = 0.45f;
    } else if (binaural) {
      wet = 0.72f;
      dry = 0.35f;
      outputGain = 0.85f;
      orbitEnabled = false;
    } else {
      wet = 0.75f;
      dry = 0.40f;
      outputGain = 0.9f;
      orbitEnabled = false;
    }
  }

  /** 8D / 双耳3D presets get runtime 360 orbit (static IR cannot pan by itself). */
  private static boolean isOrbitPresetName(String path) {
    String n = path.replace('\\', '/');
    int slash = n.lastIndexOf('/');
    if (slash >= 0) {
      n = n.substring(slash + 1);
    }
    return n.startsWith("8D") || n.startsWith("双耳");
  }

  private static float[] zerosLike(float[] src) {
    return new float[src.length];
  }

  private static final class ParsedIr {
    final float[] ll;
    @Nullable final float[] lr;
    @Nullable final float[] rl;
    @Nullable final float[] rr;
    final int channels;
    final boolean binaural;
    final int sampleRate;

    ParsedIr(
        float[] ll,
        @Nullable float[] lr,
        @Nullable float[] rl,
        @Nullable float[] rr,
        int channels,
        boolean binaural,
        int sampleRate) {
      this.ll = ll;
      this.lr = lr;
      this.rl = rl;
      this.rr = rr;
      this.channels = channels;
      this.binaural = binaural;
      this.sampleRate = sampleRate;
    }
  }

  private static ParsedIr parseWav(byte[] data) {
    ByteBuffer buf = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
    buf.position(4);
    buf.getInt(); // riff size
    if (buf.remaining() < 4 || buf.getInt() != 0x45564157) { // WAVE
      throw new IllegalArgumentException("not a WAVE file");
    }
    short audioFormat = -1;
    short channels = 1;
    int sampleRate = 44100;
    short bitsPerSample = 16;
    byte[] pcm = null;
    while (buf.remaining() >= 8) {
      int chunkId = buf.getInt();
      int chunkSize = buf.getInt();
      if (chunkSize < 0 || chunkSize > buf.remaining()) {
        break;
      }
      int next = buf.position() + chunkSize + (chunkSize & 1);
      if (chunkId == 0x20746d66) { // fmt
        audioFormat = buf.getShort();
        channels = buf.getShort();
        sampleRate = buf.getInt();
        buf.getInt(); // byte rate
        buf.getShort(); // block align
        bitsPerSample = buf.getShort();
      } else if (chunkId == 0x61746164) { // data
        pcm = new byte[chunkSize];
        buf.get(pcm);
      }
      buf.position(Math.min(next, buf.capacity()));
    }
    if (pcm == null) {
      throw new IllegalArgumentException("WAVE missing data chunk");
    }
    if (audioFormat != 1 && audioFormat != 3) {
      throw new IllegalArgumentException("unsupported WAVE format " + audioFormat);
    }
    return decodePcm(pcm, channels, bitsPerSample, audioFormat == 3, sampleRate);
  }

  private static ParsedIr parseRawIrs(byte[] data) {
    boolean stereo = data.length >= 8 && (data.length % 4) == 0 && data.length >= 64 * 1024;
    if (!stereo && data.length % 2 != 0) {
      data = Arrays.copyOf(data, data.length - 1);
    }
    short channels = (short) (stereo ? 2 : 1);
    // Viper IRS are typically 44100.
    return decodePcm(data, channels, (short) 16, false, 44100);
  }

  private static ParsedIr decodePcm(
      byte[] pcm, short channels, short bitsPerSample, boolean ieeeFloat, int sampleRate) {
    int bytesPerSample = bitsPerSample / 8;
    int frameBytes = channels * bytesPerSample;
    if (frameBytes <= 0 || pcm.length < frameBytes) {
      throw new IllegalArgumentException("pcm too short");
    }
    int frames = pcm.length / frameBytes;
    int keep = Math.min(frames, MAX_IR_SAMPLES);
    boolean binaural = channels >= 4;
    float[] ll = new float[keep];
    float[] lr = binaural || channels >= 2 ? new float[keep] : null;
    float[] rl = binaural ? new float[keep] : null;
    float[] rr = binaural || channels >= 2 ? new float[keep] : null;

    ByteBuffer buf = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN);
    for (int i = 0; i < keep; i++) {
      ll[i] = readSample(buf, bitsPerSample, ieeeFloat);
      if (channels >= 2) {
        lr[i] = readSample(buf, bitsPerSample, ieeeFloat);
      }
      if (channels >= 3) {
        float ch3 = readSample(buf, bitsPerSample, ieeeFloat);
        if (binaural) {
          rl[i] = ch3;
        }
      }
      if (channels >= 4) {
        rr[i] = readSample(buf, bitsPerSample, ieeeFloat);
      }
      for (int c = 5; c <= channels; c++) {
        readSample(buf, bitsPerSample, ieeeFloat);
      }
    }

    // Stereo WAV: ch0=L, ch1=R → independent paths (rr=ch1, lr/rl unused zeros later).
    if (!binaural && channels >= 2) {
      rr = lr;
      lr = null;
      rl = null;
    }

    int trimmed = trimTrailingSilence(ll, lr, rl, rr);
    if (trimmed < ll.length) {
      ll = Arrays.copyOf(ll, trimmed);
      if (lr != null) lr = Arrays.copyOf(lr, trimmed);
      if (rl != null) rl = Arrays.copyOf(rl, trimmed);
      if (rr != null) rr = Arrays.copyOf(rr, trimmed);
    }

    int storedChannels = binaural ? 4 : (channels >= 2 ? 2 : 1);
    int rate = sampleRate > 0 ? sampleRate : 44100;
    return new ParsedIr(ll, lr, rl, rr, storedChannels, binaural, rate);
  }

  private static float readSample(ByteBuffer buf, short bitsPerSample, boolean ieeeFloat) {
    if (ieeeFloat && bitsPerSample == 32) {
      return buf.getFloat();
    }
    if (bitsPerSample == 16) {
      return buf.getShort() / 32768.0f;
    }
    if (bitsPerSample == 24) {
      return read24(buf) / 8388608.0f;
    }
    if (bitsPerSample == 32 && !ieeeFloat) {
      return buf.getInt() / 2147483648.0f;
    }
    throw new IllegalArgumentException("unsupported bit depth " + bitsPerSample);
  }

  private static int read24(ByteBuffer buf) {
    int b0 = buf.get() & 0xff;
    int b1 = buf.get() & 0xff;
    int b2 = buf.get();
    return (b2 << 16) | (b1 << 8) | b0;
  }

  private static int trimTrailingSilence(
      float[] ll, @Nullable float[] lr, @Nullable float[] rl, @Nullable float[] rr) {
    int end = ll.length - 1;
    while (end > 16) {
      float e = Math.abs(ll[end]);
      if (lr != null) e = Math.max(e, Math.abs(lr[end]));
      if (rl != null) e = Math.max(e, Math.abs(rl[end]));
      if (rr != null) e = Math.max(e, Math.abs(rr[end]));
      if (e > 1e-4f) {
        break;
      }
      end--;
    }
    return Math.max(16, end + 1);
  }

  private static void normalizeJointPeak(
      float[] ll,
      @Nullable float[] lr,
      @Nullable float[] rl,
      @Nullable float[] rr,
      float targetPeak) {
    float peak = peakOf(ll);
    if (lr != null) peak = Math.max(peak, peakOf(lr));
    if (rl != null) peak = Math.max(peak, peakOf(rl));
    if (rr != null) peak = Math.max(peak, peakOf(rr));
    if (peak < 1e-6f) {
      return;
    }
    float scale = targetPeak / peak;
    scaleInPlace(ll, scale);
    if (lr != null) scaleInPlace(lr, scale);
    if (rl != null) scaleInPlace(rl, scale);
    if (rr != null) scaleInPlace(rr, scale);
  }

  private static float peakOf(float[] ir) {
    float peak = 0f;
    for (float v : ir) {
      peak = Math.max(peak, Math.abs(v));
    }
    return peak;
  }

  private static void scaleInPlace(float[] ir, float scale) {
    for (int i = 0; i < ir.length; i++) {
      ir[i] *= scale;
    }
  }

  /** Linear resample from {@code srcRate} to {@code dstRate}. */
  private static float[] resampleLinear(float[] src, int srcRate, int dstRate) {
    if (srcRate <= 0 || dstRate <= 0 || srcRate == dstRate || src.length == 0) {
      return Arrays.copyOf(src, src.length);
    }
    int outLen = Math.max(1, (int) Math.round(src.length * (double) dstRate / (double) srcRate));
    outLen = Math.min(outLen, MAX_IR_SAMPLES);
    float[] out = new float[outLen];
    double ratio = (double) srcRate / (double) dstRate;
    for (int i = 0; i < outLen; i++) {
      double pos = i * ratio;
      int i0 = (int) pos;
      int i1 = Math.min(i0 + 1, src.length - 1);
      float frac = (float) (pos - i0);
      if (i0 >= src.length) {
        out[i] = src[src.length - 1];
      } else {
        out[i] = src[i0] * (1f - frac) + src[i1] * frac;
      }
    }
    return out;
  }

  private static void normalizePeak(float[] ir, float targetPeak) {
    float peak = peakOf(ir);
    if (peak < 1e-6f) {
      return;
    }
    scaleInPlace(ir, targetPeak / peak);
  }

  private static byte[] readAll(File file) throws IOException {
    try (FileInputStream in = new FileInputStream(file);
        ByteArrayOutputStream out =
            new ByteArrayOutputStream((int) Math.min(file.length(), 8_000_000))) {
      byte[] buf = new byte[8192];
      int n;
      while ((n = in.read(buf)) >= 0) {
        out.write(buf, 0, n);
      }
      return out.toByteArray();
    }
  }

  private static float clamp01(float v) {
    if (v < 0f) return 0f;
    if (v > 1f) return 1f;
    return v;
  }
}
