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
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.view.View
import android.widget.ImageButton
import android.widget.TextView
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
import com.example.whispertoinput.BuildConfig

private const val RECORDED_AUDIO_FILENAME_M4A = "recorded.m4a"
private const val RECORDED_AUDIO_FILENAME_OGG = "recorded.ogg"
private const val AUDIO_MEDIA_TYPE_M4A = "audio/mp4"
private const val AUDIO_MEDIA_TYPE_OGG = "audio/ogg"
private const val AUDIO_MEDIA_TYPE_WAV = "audio/wav"

/**
 * Voice input method service with tap-to-toggle recording.
 * Tap mic to start, tap again to stop and transcribe.
 */
class WhisperInputService : InputMethodService() {
    private val whisperTranscriber: WhisperTranscriber = WhisperTranscriber()
    private var recorderManager: RecorderManager = RecorderManager()
    private var recordedAudioFilename: String = ""
    private var audioMediaType: String = AUDIO_MEDIA_TYPE_M4A
    private var useOggFormat: Boolean = false
    private var testFileModeRecording: Boolean = false  // Track test file recording state

    // UI elements
    private var micButton: ImageButton? = null
    private var statusLabel: TextView? = null

    private val toggleReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            android.util.Log.d("whisper-input", "onReceive: action=${intent?.action}")
            if (intent?.action == ACTION_TOGGLE_RECORDING) {
                toggleRecording()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        android.util.Log.d("whisper-input", "onCreate: registering receiver")
        registerReceiver(toggleReceiver, IntentFilter(ACTION_TOGGLE_RECORDING), Context.RECEIVER_EXPORTED)
        android.util.Log.d("whisper-input", "onCreate: receiver registered")
    }

    private fun transcriptionCallback(text: String?) {
        if (!text.isNullOrEmpty()) {
            lastTranscriptionResult = text
            lastTranscriptionError = null
            currentInputConnection?.commitText(text, 1)
            CoroutineScope(Dispatchers.Main).launch {
                val autoSwitchBack = dataStore.data.map { preferences: Preferences ->
                    preferences[AUTO_SWITCH_BACK] ?: false
                }.first()
                if (autoSwitchBack) {
                    switchToPreviousInputMethod()
                }
            }
        }
        updateMicUI(false)
    }

    private fun transcriptionExceptionCallback(message: String) {
        // Store error for display in MainActivity debug field
        lastTranscriptionError = message
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        updateMicUI(false)
    }

    companion object {
        const val ACTION_TOGGLE_RECORDING = "com.example.whispertoinput.action.TOGGLE_RECORDING"
        var lastTranscriptionResult: String? = null
        var lastTranscriptionError: String? = null
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

    override fun onCreateInputView(): View {
        android.util.Log.d("whisper-input", "onCreateInputView: creating keyboard view")
        val view = layoutInflater.inflate(R.layout.keyboard_view, null)

        micButton = view.findViewById(R.id.btn_mic)
        statusLabel = view.findViewById(R.id.label_status)

        micButton?.setOnClickListener {
            toggleRecording()
        }

        // Preload conversion table
        ChineseUtils.preLoad(true, TransType.SIMPLE_TO_TAIWAN)
        ChineseUtils.preLoad(true, TransType.TAIWAN_TO_SIMPLE)

        CoroutineScope(Dispatchers.Main).launch {
            updateAudioFormat()
        }

        android.util.Log.d("whisper-input", "onCreateInputView: keyboard view created")
        return view
    }

    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        // Don't auto-start — wait for mic button tap
    }

    private fun toggleRecording() {
        if (!recorderManager.allPermissionsGranted(this)) {
            launchMainActivity()
            return
        }

        // Launch coroutine to handle toggle logic (includes async DataStore reads)
        CoroutineScope(Dispatchers.Main).launch {
            // Check if test file mode is enabled (debug builds only)
            val useTestFile = if (BuildConfig.DEBUG) {
                dataStore.data
                    .map { it[USE_TEST_FILE] ?: false }
                    .first()
            } else false

            if (useTestFile) {
                // Test file mode: use testFileModeRecording flag
                if (testFileModeRecording) {
                    // Stop test file recording and transcribe
                    testFileModeRecording = false
                    updateMicUI(false)
                    statusLabel?.text = getString(R.string.transcribing)

                    val testFilePath = dataStore.data
                        .map { it[TEST_FILE_PATH] ?: "/sdcard/test-speech-loud.wav" }
                        .first()

                    whisperTranscriber.startAsync(this@WhisperInputService,
                        testFilePath,
                        AUDIO_MEDIA_TYPE_WAV,
                        "",
                        { text ->
                            android.util.Log.d("whisper-input", "Transcription result: '$text'")
                            transcriptionCallback(text)
                        },
                        { msg ->
                            android.util.Log.e("whisper-input", "Transcription error: $msg")
                            transcriptionExceptionCallback(msg)
                        })
                } else {
                    // Start test file recording (just update UI)
                    testFileModeRecording = true
                    updateMicUI(true)
                    statusLabel?.text = getString(R.string.recording)
                }
            } else if (recorderManager.isRecording) {
                // Normal mode: stop recording and transcribe
                recorderManager.stop()
                updateMicUI(false)
                statusLabel?.text = getString(R.string.transcribing)

                whisperTranscriber.startAsync(this@WhisperInputService,
                    recordedAudioFilename,
                    audioMediaType,
                    "",
                    { text ->
                        android.util.Log.d("whisper-input", "Transcription result: '$text'")
                        transcriptionCallback(text)
                    },
                    { msg ->
                        android.util.Log.e("whisper-input", "Transcription error: $msg")
                        transcriptionExceptionCallback(msg)
                    })
            } else {
                // Normal mode: start recording
                updateAudioFormat()
                recorderManager.start(this@WhisperInputService, recordedAudioFilename, useOggFormat)
                updateMicUI(true)
                statusLabel?.text = getString(R.string.recording)
            }
        }
    }

    private fun updateMicUI(isRecording: Boolean) {
        if (isRecording) {
            micButton?.setImageResource(R.drawable.mic_pressed)
            statusLabel?.text = getString(R.string.recording)
        } else {
            micButton?.setImageResource(R.drawable.mic_idle)
            statusLabel?.text = getString(R.string.whisper_to_input)
        }
    }

    private fun launchMainActivity() {
        val dialogIntent = Intent(this, MainActivity::class.java)
        dialogIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(dialogIntent)
    }

    override fun onWindowHidden() {
        super.onWindowHidden()
        android.util.Log.d("whisper-input", "onWindowHidden: isRecording=${recorderManager.isRecording}")
        if (recorderManager.isRecording) {
            recorderManager.stop()
            updateMicUI(false)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        whisperTranscriber.stop()
        recorderManager.stop()
        unregisterReceiver(toggleReceiver)
    }
}
