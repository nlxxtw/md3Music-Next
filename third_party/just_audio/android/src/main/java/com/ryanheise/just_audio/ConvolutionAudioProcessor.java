package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.BaseAudioProcessor;
import androidx.media3.common.util.UnstableApi;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/**
 * Uniformly-partitioned overlap-add FIR convolution for PCM16 streams.
 *
 * <p>Supports stereo independent IR and 4-channel binaural matrix:
 * {@code L' = L*LL + R*RL}, {@code R' = L*LR + R*RR}.
 */
@UnstableApi
public final class ConvolutionAudioProcessor extends BaseAudioProcessor {
  private static final int FFT_SIZE = 2048;
  private static final int BLOCK = FFT_SIZE / 2; // 1024

  private final ConvolutionController controller = ConvolutionController.getInstance();

  private int channelCount;
  private int sampleRate = 44100;
  private float[][] irPartsLL = new float[0][];
  private float[][] irPartsLR = new float[0][];
  private float[][] irPartsRL = new float[0][];
  private float[][] irPartsRR = new float[0][];
  private int partCount;
  private int loadedIrLength = -1;
  private int loadedPlayRate = -1;
  private boolean loadedBinaural;

  private float[][] xFftRingL = new float[0][];
  private float[][] xFftRingR = new float[0][];
  private int ringWrite;

  private final float[] inBlockL = new float[BLOCK];
  private final float[] inBlockR = new float[BLOCK];
  private int inFill;

  private final float[] overlapL = new float[BLOCK];
  private final float[] overlapR = new float[BLOCK];

  private final float[] fftBuf = new float[FFT_SIZE * 2];
  private final float[] accL = new float[FFT_SIZE * 2];
  private final float[] accR = new float[FFT_SIZE * 2];
  private final float[] timeBuf = new float[FFT_SIZE];
  private final float[] timeBufR = new float[FFT_SIZE];

  /** Haas / ITD delay lines for 360 orbit (~1.3 ms @ 48 kHz). */
  private static final int ORBIT_DELAY_LEN = 64;
  private final float[] orbitDelayL = new float[ORBIT_DELAY_LEN];
  private final float[] orbitDelayR = new float[ORBIT_DELAY_LEN];
  private int orbitDelayWrite;
  private float orbitPhase;
  private final float[] orbitTmp = new float[2];

  @Override
  public AudioFormat onConfigure(AudioFormat inputAudioFormat)
      throws UnhandledAudioFormatException {
    if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
      throw new UnhandledAudioFormatException(inputAudioFormat);
    }
    if (inputAudioFormat.channelCount <= 0 || inputAudioFormat.channelCount > 2) {
      throw new UnhandledAudioFormatException(inputAudioFormat);
    }
    channelCount = inputAudioFormat.channelCount;
    sampleRate = inputAudioFormat.sampleRate > 0 ? inputAudioFormat.sampleRate : 44100;
    // Force partition rebuild when sample rate changes (IR must be resampled).
    loadedIrLength = -1;
    loadedPlayRate = -1;
    return inputAudioFormat;
  }

  @Override
  public void queueInput(ByteBuffer inputBuffer) {
    maybeRebuildPartitions();
    if (!controller.isEnabled() || partCount == 0) {
      if (inFill != 0) {
        onFlush();
      }
      passthrough(inputBuffer);
      return;
    }

    int frameBytes = channelCount * 2;
    int frames = inputBuffer.remaining() / frameBytes;
    if (frames <= 0) {
      return;
    }

    int maxOutFrames = ((inFill + frames) / BLOCK) * BLOCK;
    ByteBuffer out = null;
    if (maxOutFrames > 0) {
      out = replaceOutputBuffer(maxOutFrames * frameBytes).order(ByteOrder.LITTLE_ENDIAN);
    }

    float wet = controller.getWet();
    float dry = controller.getDry();
    float gain = controller.getOutputGain();

    for (int n = 0; n < frames; n++) {
      inBlockL[inFill] = inputBuffer.getShort() / 32768.0f;
      inBlockR[inFill] =
          channelCount > 1 ? inputBuffer.getShort() / 32768.0f : inBlockL[inFill];
      inFill++;
      if (inFill == BLOCK) {
        if (out == null) {
          out = replaceOutputBuffer(BLOCK * frameBytes).order(ByteOrder.LITTLE_ENDIAN);
        }
        writeConvolvedBlock(out, wet, dry, gain);
        inFill = 0;
      }
    }

    if (out != null) {
      out.flip();
    }
  }

  private void writeConvolvedBlock(ByteBuffer out, float wet, float dry, float gain) {
    fftRealForward(inBlockL, xFftRingL[ringWrite]);
    if (channelCount > 1) {
      fftRealForward(inBlockR, xFftRingR[ringWrite]);
    } else {
      System.arraycopy(xFftRingL[ringWrite], 0, xFftRingR[ringWrite], 0, FFT_SIZE * 2);
    }

    Arrays.fill(accL, 0f);
    Arrays.fill(accR, 0f);
    for (int p = 0; p < partCount; p++) {
      int idx = ringWrite - p;
      if (idx < 0) {
        idx += partCount;
      }
      // L' = L*LL + R*RL
      multiplyAccumulate(xFftRingL[idx], irPartsLL[p], accL);
      multiplyAccumulate(xFftRingR[idx], irPartsRL[p], accL);
      // R' = L*LR + R*RR
      multiplyAccumulate(xFftRingL[idx], irPartsLR[p], accR);
      multiplyAccumulate(xFftRingR[idx], irPartsRR[p], accR);
    }
    ringWrite = (ringWrite + 1) % partCount;

    ifftToTime(accL, timeBuf);
    ifftToTime(accR, timeBufR);

    boolean orbit = controller.isOrbitEnabled();
    float orbitHz = controller.getOrbitHz();
    float orbitDepth = controller.getOrbitDepth();
    float phaseStep =
        orbit && sampleRate > 0 ? (float) (2.0 * Math.PI * orbitHz / sampleRate) : 0f;
    // Max ITD ~0.65 ms (enough for clear L/R without comb noise).
    int maxItd = Math.max(1, Math.min(ORBIT_DELAY_LEN - 1, sampleRate / 1500));

    for (int i = 0; i < BLOCK; i++) {
      float wetL = timeBuf[i] + overlapL[i];
      overlapL[i] = timeBuf[i + BLOCK];
      float wetR = timeBufR[i] + overlapR[i];
      overlapR[i] = timeBufR[i + BLOCK];

      if (orbit) {
        orbitPhase += phaseStep;
        if (orbitPhase > (float) (2.0 * Math.PI)) {
          orbitPhase -= (float) (2.0 * Math.PI);
        }
        float[] orb = applyOrbit(wetL, wetR, orbitPhase, orbitDepth, maxItd);
        wetL = orb[0];
        wetR = orb[1];
      }

      float outL = softLimit((dry * inBlockL[i] + wet * wetL) * gain);
      out.putShort(floatToShort(outL));
      if (channelCount > 1) {
        float outR = softLimit((dry * inBlockR[i] + wet * wetR) * gain);
        out.putShort(floatToShort(outR));
      }
    }
  }

  /**
   * Rotate a mid image around the head: equal-power pan + Haas ITD.
   * Keeps a little of the IR stereo width so it doesn't collapse to mono.
   */
  private float[] applyOrbit(float wetL, float wetR, float phase, float depth, int maxItd) {
    float mid = 0.5f * (wetL + wetR);
    float side = 0.5f * (wetL - wetR);

    // az: 0=front, +π/2=right, π=back, +3π/2=left — full 360.
    float sinA = (float) Math.sin(phase);
    float cosA = (float) Math.cos(phase);
    // Equal-power pan from sin(az): -1 left … +1 right
    float pan = sinA;
    float angle = (pan + 1f) * (float) (Math.PI / 4.0);
    float gL = (float) Math.cos(angle);
    float gR = (float) Math.sin(angle);
    // Slightly quieter behind the head (more natural circle)
    float frontBias = 0.72f + 0.28f * Math.max(0f, cosA);
    gL *= frontBias;
    gR *= frontBias;

    // Haas: delay the contralateral ear so the image "runs" around.
    int dL = pan > 0f ? Math.round(pan * maxItd) : 0;
    int dR = pan < 0f ? Math.round(-pan * maxItd) : 0;
    orbitDelayL[orbitDelayWrite] = mid;
    orbitDelayR[orbitDelayWrite] = mid;
    int idxL = orbitDelayWrite - dL;
    if (idxL < 0) idxL += ORBIT_DELAY_LEN;
    int idxR = orbitDelayWrite - dR;
    if (idxR < 0) idxR += ORBIT_DELAY_LEN;
    float delayedL = orbitDelayL[idxL];
    float delayedR = orbitDelayR[idxR];
    orbitDelayWrite = (orbitDelayWrite + 1) % ORBIT_DELAY_LEN;

    float orbL = delayedL * gL;
    float orbR = delayedR * gR;
    // Blend orbit mono-pan with a bit of IR side for width
    float width = 0.28f;
    orbitTmp[0] = depth * (orbL + width * side) + (1f - depth) * wetL;
    orbitTmp[1] = depth * (orbR - width * side) + (1f - depth) * wetR;
    return orbitTmp;
  }

  private void passthrough(ByteBuffer inputBuffer) {
    int remaining = inputBuffer.remaining();
    if (remaining == 0) {
      return;
    }
    replaceOutputBuffer(remaining).put(inputBuffer).flip();
  }

  @Override
  protected void onQueueEndOfStream() {
    if (!controller.isEnabled() || partCount == 0 || inFill == 0) {
      return;
    }
    while (inFill < BLOCK) {
      inBlockL[inFill] = 0f;
      inBlockR[inFill] = 0f;
      inFill++;
    }
    int frameBytes = channelCount * 2;
    ByteBuffer out =
        replaceOutputBuffer(BLOCK * frameBytes).order(ByteOrder.LITTLE_ENDIAN);
    writeConvolvedBlock(out, controller.getWet(), controller.getDry(), controller.getOutputGain());
    inFill = 0;
    out.flip();
  }

  @Override
  protected void onFlush() {
    inFill = 0;
    Arrays.fill(overlapL, 0f);
    Arrays.fill(overlapR, 0f);
    Arrays.fill(inBlockL, 0f);
    Arrays.fill(inBlockR, 0f);
    Arrays.fill(orbitDelayL, 0f);
    Arrays.fill(orbitDelayR, 0f);
    orbitDelayWrite = 0;
    // Keep orbitPhase so rotation stays continuous across flushes of small gaps.
    ringWrite = 0;
    for (float[] slot : xFftRingL) {
      Arrays.fill(slot, 0f);
    }
    for (float[] slot : xFftRingR) {
      Arrays.fill(slot, 0f);
    }
  }

  @Override
  protected void onReset() {
    onFlush();
    irPartsLL = new float[0][];
    irPartsLR = new float[0][];
    irPartsRL = new float[0][];
    irPartsRR = new float[0][];
    xFftRingL = new float[0][];
    xFftRingR = new float[0][];
    partCount = 0;
    loadedIrLength = -1;
    loadedPlayRate = -1;
  }

  private void maybeRebuildPartitions() {
    int nativeLen = controller.getIrLength();
    boolean binaural = controller.isBinaural();
    if (nativeLen == loadedIrLength
        && partCount > 0
        && binaural == loadedBinaural
        && sampleRate == loadedPlayRate) {
      return;
    }
    float[][] paths = controller.getPathsForRate(sampleRate);
    if (paths.length < 4 || nativeLen <= 0) {
      irPartsLL = new float[0][];
      irPartsLR = new float[0][];
      irPartsRL = new float[0][];
      irPartsRR = new float[0][];
      xFftRingL = new float[0][];
      xFftRingR = new float[0][];
      partCount = 0;
      loadedIrLength = nativeLen;
      loadedPlayRate = sampleRate;
      loadedBinaural = binaural;
      return;
    }
    float[] srcLL = paths[0];
    float[] srcLR = paths[1];
    float[] srcRL = paths[2];
    float[] srcRR = paths[3];
    int len = srcLL.length;

    partCount = (len + BLOCK - 1) / BLOCK;
    irPartsLL = new float[partCount][];
    irPartsLR = new float[partCount][];
    irPartsRL = new float[partCount][];
    irPartsRR = new float[partCount][];
    xFftRingL = new float[partCount][];
    xFftRingR = new float[partCount][];
    float[] tmp = new float[BLOCK];
    for (int p = 0; p < partCount; p++) {
      int start = p * BLOCK;
      int n = Math.min(BLOCK, len - start);

      irPartsLL[p] = partitionFft(srcLL, start, n, tmp);
      irPartsLR[p] = partitionFft(srcLR, start, n, tmp);
      irPartsRL[p] = partitionFft(srcRL, start, n, tmp);
      irPartsRR[p] = partitionFft(srcRR, start, n, tmp);

      xFftRingL[p] = new float[FFT_SIZE * 2];
      xFftRingR[p] = new float[FFT_SIZE * 2];
    }
    loadedIrLength = nativeLen;
    loadedPlayRate = sampleRate;
    loadedBinaural = binaural;
    ringWrite = 0;
    Arrays.fill(overlapL, 0f);
    Arrays.fill(overlapR, 0f);
    inFill = 0;
  }

  private float[] partitionFft(float[] src, int start, int n, float[] tmp) {
    Arrays.fill(tmp, 0f);
    System.arraycopy(src, start, tmp, 0, n);
    float[] out = new float[FFT_SIZE * 2];
    fftRealForward(tmp, out);
    return out;
  }

  private static void multiplyAccumulate(float[] x, float[] h, float[] acc) {
    for (int i = 0; i < FFT_SIZE; i++) {
      int re = i * 2;
      int im = re + 1;
      float a = x[re];
      float b = x[im];
      float c = h[re];
      float d = h[im];
      acc[re] += a * c - b * d;
      acc[im] += a * d + b * c;
    }
  }

  private void fftRealForward(float[] realBlock, float[] outInterleaved) {
    Arrays.fill(fftBuf, 0f);
    for (int i = 0; i < realBlock.length; i++) {
      fftBuf[i * 2] = realBlock[i];
    }
    fft(fftBuf, false);
    System.arraycopy(fftBuf, 0, outInterleaved, 0, FFT_SIZE * 2);
  }

  private void ifftToTime(float[] freqInterleaved, float[] outReal) {
    System.arraycopy(freqInterleaved, 0, fftBuf, 0, FFT_SIZE * 2);
    fft(fftBuf, true);
    for (int i = 0; i < FFT_SIZE; i++) {
      outReal[i] = fftBuf[i * 2];
    }
  }

  private static void fft(float[] a, boolean inverse) {
    int n = FFT_SIZE;
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        int ri = i * 2;
        int rj = j * 2;
        float tr = a[ri];
        float ti = a[ri + 1];
        a[ri] = a[rj];
        a[ri + 1] = a[rj + 1];
        a[rj] = tr;
        a[rj + 1] = ti;
      }
    }
    for (int len = 2; len <= n; len <<= 1) {
      double ang = 2 * Math.PI / len * (inverse ? 1 : -1);
      float wlenRe = (float) Math.cos(ang);
      float wlenIm = (float) Math.sin(ang);
      for (int i = 0; i < n; i += len) {
        float wRe = 1f;
        float wIm = 0f;
        for (int j = 0; j < len / 2; j++) {
          int u = (i + j) * 2;
          int v = (i + j + len / 2) * 2;
          float uRe = a[u];
          float uIm = a[u + 1];
          float vRe = a[v] * wRe - a[v + 1] * wIm;
          float vIm = a[v] * wIm + a[v + 1] * wRe;
          a[u] = uRe + vRe;
          a[u + 1] = uIm + vIm;
          a[v] = uRe - vRe;
          a[v + 1] = uIm - vIm;
          float nextWRe = wRe * wlenRe - wIm * wlenIm;
          wIm = wRe * wlenIm + wIm * wlenRe;
          wRe = nextWRe;
        }
      }
    }
    if (inverse) {
      float inv = 1.0f / n;
      for (int i = 0; i < n * 2; i++) {
        a[i] *= inv;
      }
    }
  }

  /** Soft knee limiter — hard clip was the main "杂音" source when wet+dry peaked. */
  private static float softLimit(float v) {
    if (v > 0.9f) {
      return 0.9f + 0.1f * (float) Math.tanh((v - 0.9f) / 0.1f);
    }
    if (v < -0.9f) {
      return -0.9f + 0.1f * (float) Math.tanh((v + 0.9f) / 0.1f);
    }
    return v;
  }

  private static short floatToShort(float v) {
    if (v > 1f) v = 1f;
    if (v < -1f) v = -1f;
    return (short) Math.round(v * 32767f);
  }
}
