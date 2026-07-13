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

import android.content.Context
import android.util.Log
import androidx.datastore.preferences.core.Preferences
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import com.github.liuyueyi.quick.transfer.ChineseUtils

class WhisperTranscriber {
    private data class Config(
        val endpoint: String,
        val languageCode: String,
        val speechToTextBackend: String,
        val apiKey: String,
        val model: String,
        val postprocessing: String,
        val addTrailingSpace: Boolean
    )

    private val TAG = "WhisperTranscriber"
    private var currentTranscriptionJob: Job? = null

    fun startAsync(
        context: Context,
        filename: String,
        mediaType: String,
        attachToEnd: String,
        callback: (String?) -> Unit,
        exceptionCallback: (String) -> Unit
    ) {
        suspend fun makeWhisperRequest(): String {
            // Retrieve configs
            val (endpoint, languageCode, speechToTextBackend, apiKey, model, postprocessing, addTrailingSpace) = context.dataStore.data.map { preferences: Preferences ->
                Config(
                    preferences[ENDPOINT] ?: "",
                    preferences[LANGUAGE_CODE] ?: "",
                    preferences[SPEECH_TO_TEXT_BACKEND] ?: context.getString(R.string.settings_option_openai_api),
                    preferences[API_KEY] ?: "",
                    preferences[MODEL] ?: "",
                    preferences[POSTPROCESSING] ?: context.getString(R.string.settings_option_no_conversion),
                    preferences[ADD_TRAILING_SPACE] ?: false
                )
            }.first()

            // Foolproof message
            if (endpoint == "") {
                throw Exception(context.getString(R.string.error_endpoint_unset))
            }

            // Make request
            val client = OkHttpClient()
            val request = buildWhisperRequest(
                context,
                filename,
                mediaType,
                speechToTextBackend,
                endpoint,
                languageCode,
                apiKey,
                model
            )
            val response = client.newCall(request).execute()

            // If request is not successful, or response code is weird
            if (!response.isSuccessful || response.code / 100 != 2) {
                throw Exception(response.body!!.string().replace('\n', ' '))
            }

            var rawText = response.body!!.string().trim()
            
            // Handle Voxtral response: {"text": "transcription"}
            if (speechToTextBackend == context.getString(R.string.settings_option_voxtral)) {
                try {
                    val json = JSONObject(rawText)
                    rawText = json.optString("text", "").trim()
                } catch (e: JSONException) {
                    // If not JSON, use as-is
                }
            }
            
            // Handle ElevenLabs response: {"text": "transcription", "language_code": "en", ...}
            if (speechToTextBackend == context.getString(R.string.settings_option_elevenlabs)) {
                try {
                    val json = JSONObject(rawText)
                    rawText = json.optString("text", "").trim()
                } catch (e: JSONException) {
                    // If not JSON, use as-is
                }
            }
            
            // For NVIDIA NIM, remove quotes if they wrap the text
            // Not sure if this is a bug or a feature...
            if (speechToTextBackend == context.getString(R.string.settings_option_nvidia_nim) && 
                rawText.startsWith("\"") && rawText.endsWith("\"")) {
                rawText = rawText.substring(1, rawText.length - 1).trim()
            }
            
            val processedText = when (postprocessing) {
                context.getString(R.string.settings_option_to_simplified) -> ChineseUtils.tw2s(rawText)
                context.getString(R.string.settings_option_to_traditional) -> ChineseUtils.s2tw(rawText)
                else -> rawText // No conversion
            }

            if (attachToEnd == "") {
                return processedText + if (addTrailingSpace) " " else ""
            } else {
                // Only used for space key and enter key.
                return processedText + attachToEnd
            }
        }

        // Create a cancellable job in the main thread (for UI updating)
        val job = CoroutineScope(Dispatchers.Main).launch {

            // Within the job, make a suspend call at the I/O thread
            // It suspends before result is obtained.
            // Returns (transcribed string, exception message)
            val (transcribedText, exceptionMessage) = withContext(Dispatchers.IO) {
                try {
                    // Perform transcription here
                    val response = makeWhisperRequest()
                    // Clean up unused audio file after transcription
                    // Ref: https://developer.android.com/reference/android/media/MediaRecorder#setOutputFile(java.io.File)
                    File(filename).delete()
                    return@withContext Pair(response, null)
                } catch (e: CancellationException) {
                    // Task was canceled
                    return@withContext Pair(null, null)
                } catch (e: Exception) {
                    return@withContext Pair(null, e.message)
                }
            }

            // This callback is within the main thread.
            callback.invoke(transcribedText)

            // If exception message is not null
            if (!exceptionMessage.isNullOrEmpty()) {
                Log.e(TAG, exceptionMessage)
                exceptionCallback(exceptionMessage)
            }
        }

        registerTranscriptionJob(job)
    }

    fun stop() {
        registerTranscriptionJob(null)
    }

    private fun registerTranscriptionJob(job: Job?) {
        currentTranscriptionJob?.cancel()
        currentTranscriptionJob = job
    }

    private fun buildWhisperRequest(
        context: Context,
        filename: String,
        mediaType: String,
        speechToTextBackend: String,
        endpoint: String,
        languageCode: String,
        apiKey: String,
        model: String
    ): Request {
        val file: File = File(filename)
        val fileBody: RequestBody = file.asRequestBody(mediaType.toMediaTypeOrNull())
        val requestBody: RequestBody = MultipartBody.Builder().apply {
            setType(MultipartBody.FORM)
            val formDataFilename = if (mediaType == "audio/ogg") "@audio.ogg" else "@audio.m4a"

            // File field
            when (speechToTextBackend) {
                context.getString(R.string.settings_option_openai_api),
                context.getString(R.string.settings_option_nvidia_nim),
                context.getString(R.string.settings_option_voxtral),
                context.getString(R.string.settings_option_elevenlabs) -> {
                    addFormDataPart("file", formDataFilename, fileBody)
                }
                context.getString(R.string.settings_option_whisper_asr_webservice) -> {
                    addFormDataPart("audio_file", formDataFilename, fileBody)
                }
            }

            // Provider-specific parameters
            when (speechToTextBackend) {
                context.getString(R.string.settings_option_openai_api) -> {
                    addFormDataPart("model", model)
                    addFormDataPart("response_format", "text")
                }
                context.getString(R.string.settings_option_nvidia_nim) -> {
                    addFormDataPart("language", languageCode)
                    addFormDataPart("response_format", "text")
                }
                context.getString(R.string.settings_option_voxtral) -> {
                    addFormDataPart("model", model)
                    if (languageCode != "auto" && languageCode.isNotEmpty()) {
                        addFormDataPart("language", languageCode)
                    }
                }
                context.getString(R.string.settings_option_elevenlabs) -> {
                    addFormDataPart("model_id", model)
                    if (languageCode != "auto" && languageCode.isNotEmpty()) {
                        addFormDataPart("language_code", languageCode)
                    }
                }
            }
        }.build()

        // Headers - NO manual Content-Type (OkHttp adds boundary)
        val requestHeaders: Headers = Headers.Builder().apply {
            when (speechToTextBackend) {
                context.getString(R.string.settings_option_openai_api),
                context.getString(R.string.settings_option_voxtral) -> {
                    if (apiKey == "") {
                        throw Exception(context.getString(R.string.error_apikey_unset))
                    }
                    add("Authorization", "Bearer $apiKey")
                }
                context.getString(R.string.settings_option_elevenlabs) -> {
                    if (apiKey == "") {
                        throw Exception(context.getString(R.string.error_apikey_unset))
                    }
                    add("xi-api-key", apiKey)
                }
            }
        }.build()

        // URL building - FIXED: separate OpenAI from Whisper ASR Webservice
        val url = when (speechToTextBackend) {
            context.getString(R.string.settings_option_whisper_asr_webservice) -> {
                // Whisper ASR Webservice uses query params
                "$endpoint?encode=true&task=transcribe&language=$languageCode&word_timestamps=false&output=txt"
            }
            else -> endpoint  // OpenAI, NVIDIA NIM, Voxtral, ElevenLabs use direct endpoint
        }

        return Request.Builder()
            .headers(requestHeaders)
            .url(url)
            .post(requestBody)
            .build()
    }
}
