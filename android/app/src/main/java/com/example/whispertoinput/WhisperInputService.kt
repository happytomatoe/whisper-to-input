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

package com.example.whispertoinput

import android.inputmethodservice.InputMethodService
import android.view.View
import android.content.Intent
import android.widget.Toast
import androidx.datastore.preferences.core.Preferences
import com.example.whispertoinput.recorder.RecorderManager
import com.github.liuyueyi.quick.transfer.ChineseUtils
import com.github.liuyueyi.quick.transfer.constants.TransType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.io.File

private const val RECORDED_AUDIO_FILENAME_M4A = "recorded.m4a"
private const val RECORDED_AUDIO_FILENAME_OGG = "recorded.ogg"
private const val AUDIO_MEDIA_TYPE_M4A = "audio/mp4"
private const val AUDIO_MEDIA_TYPE_OGG = "audio/ogg"

/**
 * Voice-only input method service.
 * This service provides voice typing functionality without a keyboard UI.
 * It works as a voice input engine that can be selected alongside Google Voice Typing.
 */
class WhisperInputService : InputMethodService() {
    private val whisperTranscriber: WhisperTranscriber = WhisperTranscriber()
    private var recorderManager: RecorderManager? = null
    private var recordedAudioFilename: String = ""
    private var audioMediaType: String = AUDIO_MEDIA_TYPE_M4A
    private var useOggFormat: Boolean = false
    private var isRecording: Boolean = false

    private fun transcriptionCallback(text: String?) {
        if (!text.isNullOrEmpty()) {
            currentInputConnection?.commitText(text, 1)
            // Check if auto-switch-back is enabled and switch if so
            CoroutineScope(Dispatchers.Main).launch {
                val autoSwitchBack = dataStore.data.map { preferences: Preferences ->
                    preferences[AUTO_SWITCH_BACK] ?: false
                }.first()
                if (autoSwitchBack) {
                    switchToPreviousInputMethod()
                }
            }
        }
        isRecording = false
    }

    private fun transcriptionExceptionCallback(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        isRecording = false
    }

    private suspend fun updateAudioFormat() {
        val backend = dataStore.data.map { preferences: Preferences ->
            preferences[SPEECH_TO_TEXT_BACKEND] ?: getString(R.string.settings_option_openai_api)
        }.first()
        
        useOggFormat = backend == getString(R.string.settings_option_nvidia_nim)
        if (useOggFormat) {
            recordedAudioFilename = "${externalCacheDir?.absolutePath}/${RECORDED_AUDIO_FILENAME_OGG}"
            audioMediaType = AUDIO_MEDIA_TYPE_OGG
        } else {
            recordedAudioFilename = "${externalCacheDir?.absolutePath}/${RECORDED_AUDIO_FILENAME_M4A}"
            audioMediaType = AUDIO_MEDIA_TYPE_M4A
        }
    }

    /**
     * For a voice-only IME, we return an empty view.
     * The system handles showing the mic button and triggering voice input.
     */
    override fun onCreateInputView(): View {
        // Initialize members
        recorderManager = RecorderManager(this).apply {
            setOnRecorderStateChange { state ->
                handleRecorderStateChange(state)
            }
        }

        // Preload conversion table
        ChineseUtils.preLoad(true, TransType.SIMPLE_TO_TAIWAN)
        ChineseUtils.preLoad(true, TransType.TAIWAN_TO_SIMPLE)

        // Initialize audio format based on backend setting
        CoroutineScope(Dispatchers.Main).launch {
            updateAudioFormat()
        }

        // Return an empty view - this is a voice-only IME
        return View(this)
    }

    /**
     * Called when the IME is started. For voice input, we auto-start recording.
     */
    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        
        // Auto-start recording when the voice IME is activated
        if (!isRecording && !restarting) {
            CoroutineScope(Dispatchers.Main).launch {
                updateAudioFormat()
                startRecording()
            }
        }
    }

    private fun startRecording() {
        // Check audio permission
        if (!recorderManager!!.allPermissionsGranted(this)) {
            launchMainActivity()
            return
        }

        recorderManager!!.start(this, recordedAudioFilename, useOggFormat)
        isRecording = true
    }

    private fun stopRecordingAndTranscribe() {
        if (isRecording) {
            recorderManager!!.stop()
            whisperTranscriber.startAsync(this,
                recordedAudioFilename,
                audioMediaType,
                "",
                { transcriptionCallback(it) },
                { transcriptionExceptionCallback(it) })
        }
    }

    private fun launchMainActivity() {
        val dialogIntent = Intent(this, MainActivity::class.java)
        dialogIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(dialogIntent)
    }

    private fun handleRecorderStateChange(state: RecorderManager.RecorderState) {
        when (state) {
            RecorderManager.RecorderState.Finish -> {
                // End of speech detected -> transcribe
                stopRecordingAndTranscribe()
            }
            RecorderManager.RecorderState.Cancelled -> {
                // No speech detected within timeout -> stop recording
                recorderManager?.stop()
                isRecording = false
            }
            else -> { }
        }
    }

    override fun onWindowHidden() {
        super.onWindowHidden()
        // If we are already transcribing or finished, let the transcription complete
        // Otherwise, stop everything
        val currentState = recorderManager?.getCurrentState()
        if (currentState != RecorderManager.RecorderState.Finish) {
            whisperTranscriber.stop()
            recorderManager?.stop()
            isRecording = false
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        whisperTranscriber.stop()
        recorderManager?.stop()
    }
}
