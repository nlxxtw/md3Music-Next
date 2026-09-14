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
 * <p>Always configured active so enable/disable can toggle without rebuilding the sink.
 * When disabled or no IR is loaded, samples are passed through unchanged.
 */
@UnstableApi
public final class ConvolutionAudioProcessor extends BaseAudioProcessor {
  private static final int FFT_SIZE = 2048;
  private static final int BLOCK = FFT_SIZE / 2; // 1024

  private final ConvolutionController controller = ConvolutionController.getInstance();

  private int channelCount;
  private float[][] irPartsL = new float[0][];
  private float[][] irPartsR = new float[0][];
  private int partCount;
  private int loadedIrLength = -1;

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
      multiplyAccumulate(xFftRingL[idx], irPartsL[p], accL);
      multiplyAccumulate(xFftRingR[idx], irPartsR[p], accR);
    }
    ringWrite = (ringWrite + 1) % partCount;

    ifftToTime(accL, timeBuf);
    if (channelCount > 1) {
      ifftToTime(accR, timeBufR);
    } else {
      System.arraycopy(timeBuf, 0, timeBufR, 0, FFT_SIZE);
    }

    for (int i = 0; i < BLOCK; i++) {
      float wetL = timeBuf[i] + overlapL[i];
      overlapL[i] = timeBuf[i + BLOCK];
      float outL = (dry * inBlockL[i] + wet * wetL) * gain;
      out.putShort(clampToShort(outL));
      if (channelCount > 1) {
        float wetR = timeBufR[i] + overlapR[i];
        overlapR[i] = timeBufR[i + BLOCK];
        float outR = (dry * inBlockR[i] + wet * wetR) * gain;
        out.putShort(clampToShort(outR));
      }
    }
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
    irPartsL = new float[0][];
    irPartsR = new float[0][];
    xFftRingL = new float[0][];
    xFftRingR = new float[0][];
    partCount = 0;
    loadedIrLength = -1;
  }

  private void maybeRebuildPartitions() {
    int len = controller.getIrLength();
    if (len == loadedIrLength && partCount > 0) {
      return;
    }
    float[] srcL = controller.getIrL();
    float[] srcR = controller.getIrR();
    if (srcL == null || len <= 0) {
      irPartsL = new float[0][];
      irPartsR = new float[0][];
      xFftRingL = new float[0][];
      xFftRingR = new float[0][];
      partCount = 0;
      loadedIrLength = len;
      return;
    }
    if (srcR == null) {
      srcR = srcL;
    }
    partCount = (len + BLOCK - 1) / BLOCK;
    irPartsL = new float[partCount][];
    irPartsR = new float[partCount][];
    xFftRingL = new float[partCount][];
    xFftRingR = new float[partCount][];
    float[] tmp = new float[BLOCK];
    for (int p = 0; p < partCount; p++) {
      int start = p * BLOCK;
      int n = Math.min(BLOCK, len - start);

      Arrays.fill(tmp, 0f);
      System.arraycopy(srcL, start, tmp, 0, n);
      irPartsL[p] = new float[FFT_SIZE * 2];
      fftRealForward(tmp, irPartsL[p]);

      Arrays.fill(tmp, 0f);
      System.arraycopy(srcR, start, tmp, 0, n);
      irPartsR[p] = new float[FFT_SIZE * 2];
      fftRealForward(tmp, irPartsR[p]);

      xFftRingL[p] = new float[FFT_SIZE * 2];
      xFftRingR[p] = new float[FFT_SIZE * 2];
    }
    loadedIrLength = len;
    ringWrite = 0;
    Arrays.fill(overlapL, 0f);
    Arrays.fill(overlapR, 0f);
    inFill = 0;
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

  private static short clampToShort(float v) {
    if (v > 1f) v = 1f;
    if (v < -1f) v = -1f;
    return (short) Math.round(v * 32767f);
  }
}
