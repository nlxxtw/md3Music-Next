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
 * <p>Loads Viper-style .irs (raw PCM) and .wav files, keeps wet/dry and enable flags
 * readable from the audio thread without allocations after load.
 */
public final class ConvolutionController {
  private static final ConvolutionController INSTANCE = new ConvolutionController();

  /** Max impulse length kept per channel (samples). Longer IRs are truncated. */
  public static final int MAX_IR_SAMPLES = 32768;

  private volatile boolean enabled;
  private volatile float wet = 0.85f;
  private volatile float dry = 0.35f;
  private volatile float outputGain = 1.0f;

  @Nullable private volatile float[] irL;
  @Nullable private volatile float[] irR;
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
  public float[] getIrL() {
    return irL;
  }

  @Nullable
  public float[] getIrR() {
    return irR;
  }

  public synchronized void clear() {
    irL = null;
    irR = null;
    irLength = 0;
    irChannels = 1;
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
    normalizePeak(parsed.left, 0.92f);
    if (parsed.right != null) {
      normalizePeak(parsed.right, 0.92f);
    }
    irL = parsed.left;
    irR = parsed.right != null ? parsed.right : parsed.left;
    irLength = parsed.left.length;
    irChannels = parsed.channels;
    loadedPath = label == null ? "" : label;
  }

  private static final class ParsedIr {
    final float[] left;
    @Nullable final float[] right;
    final int channels;

    ParsedIr(float[] left, @Nullable float[] right, int channels) {
      this.left = left;
      this.right = right;
      this.channels = channels;
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
    // Viper IRS: usually little-endian PCM16. Stereo if frame-aligned and long enough.
    boolean stereo = data.length >= 8 && (data.length % 4) == 0 && data.length >= 64 * 1024;
    if (!stereo && data.length % 2 != 0) {
      data = Arrays.copyOf(data, data.length - 1);
    }
    short channels = (short) (stereo ? 2 : 1);
    return decodePcm(data, channels, (short) 16, false);
  }

  private static ParsedIr decodePcm(
      byte[] pcm, short channels, short bitsPerSample, boolean ieeeFloat) {
    int frameBytes = channels * (bitsPerSample / 8);
    if (frameBytes <= 0 || pcm.length < frameBytes) {
      throw new IllegalArgumentException("pcm too short");
    }
    int frames = pcm.length / frameBytes;
    int keep = Math.min(frames, MAX_IR_SAMPLES);
    float[] left = new float[keep];
    float[] right = channels >= 2 ? new float[keep] : null;
    ByteBuffer buf = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN);
    for (int i = 0; i < keep; i++) {
      if (ieeeFloat && bitsPerSample == 32) {
        left[i] = buf.getFloat();
        if (right != null) {
          right[i] = buf.getFloat();
          for (int c = 2; c < channels; c++) {
            buf.getFloat();
          }
        } else {
          for (int c = 1; c < channels; c++) {
            buf.getFloat();
          }
        }
      } else if (bitsPerSample == 16) {
        left[i] = buf.getShort() / 32768.0f;
        if (right != null) {
          right[i] = buf.getShort() / 32768.0f;
          for (int c = 2; c < channels; c++) {
            buf.getShort();
          }
        } else {
          for (int c = 1; c < channels; c++) {
            buf.getShort();
          }
        }
      } else if (bitsPerSample == 24) {
        left[i] = read24(buf) / 8388608.0f;
        if (right != null) {
          right[i] = read24(buf) / 8388608.0f;
          for (int c = 2; c < channels; c++) {
            read24(buf);
          }
        } else {
          for (int c = 1; c < channels; c++) {
            read24(buf);
          }
        }
      } else if (bitsPerSample == 32 && !ieeeFloat) {
        left[i] = buf.getInt() / 2147483648.0f;
        if (right != null) {
          right[i] = buf.getInt() / 2147483648.0f;
          for (int c = 2; c < channels; c++) {
            buf.getInt();
          }
        } else {
          for (int c = 1; c < channels; c++) {
            buf.getInt();
          }
        }
      } else {
        throw new IllegalArgumentException("unsupported bit depth " + bitsPerSample);
      }
    }
    int trimmed = trimTrailingSilence(left, right);
    if (trimmed < left.length) {
      left = Arrays.copyOf(left, trimmed);
      if (right != null) {
        right = Arrays.copyOf(right, trimmed);
      }
    }
    return new ParsedIr(left, right, channels >= 2 ? 2 : 1);
  }

  private static int read24(ByteBuffer buf) {
    int b0 = buf.get() & 0xff;
    int b1 = buf.get() & 0xff;
    int b2 = buf.get();
    return (b2 << 16) | (b1 << 8) | b0;
  }

  private static int trimTrailingSilence(float[] left, @Nullable float[] right) {
    int end = left.length - 1;
    while (end > 16) {
      float e = Math.abs(left[end]);
      if (right != null) {
        e = Math.max(e, Math.abs(right[end]));
      }
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
        ByteArrayOutputStream out = new ByteArrayOutputStream((int) Math.min(file.length(), 4_000_000))) {
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
