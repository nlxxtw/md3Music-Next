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

  /** True when IR is 4-channel binaural matrix. */
  private volatile boolean binaural;

  @Nullable private volatile float[] irLL;
  @Nullable private volatile float[] irLR;
  @Nullable private volatile float[] irRL;
  @Nullable private volatile float[] irRR;
  private volatile int irLength;
  private volatile int irChannels = 1;
  private volatile String loadedPath = "";

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

  public String getLoadedPath() {
    return loadedPath;
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
    binaural = false;
    loadedPath = "";
    enabled = false;
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
    normalizePeak(parsed.ll, 0.92f);
    if (parsed.lr != null) normalizePeak(parsed.lr, 0.92f);
    if (parsed.rl != null) normalizePeak(parsed.rl, 0.92f);
    if (parsed.rr != null) normalizePeak(parsed.rr, 0.92f);

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
    binaural = parsed.binaural;
    loadedPath = label == null ? "" : label;

    // Binaural spatial IRs benefit from a wetter default mix.
    if (binaural) {
      wet = 0.92f;
      dry = 0.28f;
    } else {
      wet = 0.85f;
      dry = 0.35f;
    }
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

    ParsedIr(
        float[] ll,
        @Nullable float[] lr,
        @Nullable float[] rl,
        @Nullable float[] rr,
        int channels,
        boolean binaural) {
      this.ll = ll;
      this.lr = lr;
      this.rl = rl;
      this.rr = rr;
      this.channels = channels;
      this.binaural = binaural;
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
        buf.getInt(); // sample rate
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
    return decodePcm(pcm, channels, bitsPerSample, audioFormat == 3);
  }

  private static ParsedIr parseRawIrs(byte[] data) {
    boolean stereo = data.length >= 8 && (data.length % 4) == 0 && data.length >= 64 * 1024;
    if (!stereo && data.length % 2 != 0) {
      data = Arrays.copyOf(data, data.length - 1);
    }
    short channels = (short) (stereo ? 2 : 1);
    return decodePcm(data, channels, (short) 16, false);
  }

  private static ParsedIr decodePcm(
      byte[] pcm, short channels, short bitsPerSample, boolean ieeeFloat) {
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
    return new ParsedIr(ll, lr, rl, rr, storedChannels, binaural);
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

  private static void normalizePeak(float[] ir, float targetPeak) {
    float peak = 0f;
    for (float v : ir) {
      peak = Math.max(peak, Math.abs(v));
    }
    if (peak < 1e-6f) {
      return;
    }
    float scale = targetPeak / peak;
    for (int i = 0; i < ir.length; i++) {
      ir[i] *= scale;
    }
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
