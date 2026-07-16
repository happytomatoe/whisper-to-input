/*
 * This file is part of Whisper To Input, see <https://github.com/j3soon/whisper-to-input>.
 *
 * Copyright (c) 2023-2025 Yan-Bin Diau, Johnson Sun
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

package com.example.whispertoinput.recorder

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.io.IOException

private const val MEDIA_RECORDER_CONSTRUCTOR_DEPRECATION_API_LEVEL = 31

/**
 * Simple recorder that starts/stops on demand.
 * No FSM, no amplitude monitoring — just record and stop.
 */
class RecorderManager {
    companion object {
        fun requiredPermissions() = arrayOf(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.POST_NOTIFICATIONS
        )
    }

    private var recorder: MediaRecorder? = null
    private var _isRecording: Boolean = false

    val isRecording: Boolean get() = _isRecording

    fun start(context: Context, filename: String, useOggFormat: Boolean = false) {
        stop()  // Clean up any previous recorder

        recorder =
            if (Build.VERSION.SDK_INT >= MEDIA_RECORDER_CONSTRUCTOR_DEPRECATION_API_LEVEL) {
                MediaRecorder(context)
            } else {
                MediaRecorder()
            }

        val file = File(filename)
        if (file.exists()) {
            file.delete()
        }

        recorder!!.apply {
            setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            if (useOggFormat) {
                setOutputFormat(MediaRecorder.OutputFormat.OGG)
                setAudioEncoder(MediaRecorder.AudioEncoder.OPUS)
            } else {
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AMR_NB)
            }
            setOutputFile(filename)

            try {
                prepare()
            } catch (e: IOException) {
                Log.e("whisper-input", "prepare() failed")
                return
            }

            start()
        }
        _isRecording = true
        Log.d("whisper-input", "Recording started: $filename")
    }

    fun stop() {
        recorder?.apply {
            try {
                stop()
            } catch (e: IllegalStateException) {
                Log.e("whisper-input", "stop() failed: ${e.message}")
            }
            release()
        }
        recorder = null
        _isRecording = false
    }

    fun allPermissionsGranted(context: Context): Boolean {
        for (permission in requiredPermissions()) {
            if (ContextCompat.checkSelfPermission(
                    context,
                    permission
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                return false
            }
        }
        return true
    }
}
