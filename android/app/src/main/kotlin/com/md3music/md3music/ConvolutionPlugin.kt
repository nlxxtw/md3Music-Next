package com.md3music.md3music

import android.util.Log
import com.ryanheise.just_audio.ConvolutionController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 本地 IRS 卷积音效：Dart 解压脉冲文件后，通过 path 加载到
 * just_audio 内的 [ConvolutionController]。
 */
class ConvolutionPlugin {

    companion object {
        private const val TAG = "ConvolutionPlugin"
        private const val CHANNEL = "com.md3music.md3music/convolution"
    }

    private var channel: MethodChannel? = null

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "loadPath" -> {
                    val path = call.argument<String>("path") ?: ""
                    if (path.isEmpty()) {
                        result.error("BAD_ARGS", "path required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val ctrl = ConvolutionController.getInstance()
                        ctrl.loadFromFile(path)
                        ctrl.setEnabled(true)
                        result.success(
                            mapOf(
                                "path" to path,
                                "irLength" to ctrl.irLength,
                                "channels" to ctrl.irChannels,
                            ),
                        )
                    } catch (e: Exception) {
                        Log.e(TAG, "loadPath failed", e)
                        result.error("LOAD_FAILED", e.message, null)
                    }
                }
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    ConvolutionController.getInstance().setEnabled(enabled)
                    result.success(true)
                }
                "setMix" -> {
                    val wet = (call.argument<Number>("wet") ?: 0.85).toFloat()
                    val dry = (call.argument<Number>("dry") ?: 0.35).toFloat()
                    ConvolutionController.getInstance().setMix(wet, dry)
                    result.success(true)
                }
                "clear" -> {
                    ConvolutionController.getInstance().clear()
                    result.success(true)
                }
                "status" -> {
                    val ctrl = ConvolutionController.getInstance()
                    result.success(
                        mapOf(
                            "enabled" to ctrl.isEnabled,
                            "irLength" to ctrl.irLength,
                            "channels" to ctrl.irChannels,
                            "path" to ctrl.loadedPath,
                            "wet" to ctrl.wet,
                            "dry" to ctrl.dry,
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        }
    }
}
