package com.phonetool.phone_ai_assistant

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private var audioRecord: AudioRecord? = null
    private var recordFile: File? = null
    private val isRecording = AtomicBoolean(false)
    private var calendar: CalendarChannel? = null
    private val share = ShareIntentChannel(this)
    private var music: MusicChannel? = null

    companion object {
        private const val CHANNEL = "voice_recorder"
        private const val SAMPLE_RATE = 16000
    }

    // 这里曾经有过一个 attachBaseContext 覆写：把 App 存的主题翻译成这个 Activity 的
    // uiMode，想让冷启动那层启动窗口跟着 App 的深色走。**试过，无效，已删**——
    // Android 12+ 的启动画面是**系统**合成的（拿 manifest 里的主题、按系统的深浅挑
    // values-night），那一帧在 App 进程起来之前就画好了，attachBaseContext 再早也够不着。
    // 留着不只有名无实，还有副作用：它会把 Activity 的 configuration 钉死成 App 的
    // 选择，而 Flutter 的 platformBrightness 是从 view 的 configuration 推的——于是
    // 「启动时是深色」的情况下再切回「跟随系统」，App 会以为系统也是深色。
    // 真正的解法见 res/values/styles.xml 里的 windowDisablePreview。

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> {
                    val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                }
                "start" -> startRecording(result)
                "stop" -> stopRecording(result)
                "cancel" -> {
                    cancelRecording()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val cal = CalendarChannel(this)
        calendar = cal
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CalendarChannel.CHANNEL)
            .setMethodCallHandler { call, result -> cal.handle(call, result) }

        // 用 applicationContext 而不是 this：查使用情况不碰界面，也不申请
        // 运行时权限，没有理由拿着 Activity 的引用多活一会儿。
        val usage = AppUsageChannel(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AppUsageChannel.CHANNEL)
            .setMethodCallHandler { call, result -> usage.handle(call, result) }

        // 别人分享过来的文字。只有读书版挂了 ACTION_SEND，主 App 这里恒空。
        // 要在 configureFlutterEngine 里就把冷启动那份存下来——等 Dart 上来
        // 取的时候 intent 早就不新鲜了，但存着的那份还在。
        share.attach(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ShareIntentChannel.CHANNEL)
        )
        share.onCreate(intent)

        // 「一起听歌」。数据在 MusicBridge 里，这里只是把管子插上——注意
        // **attach 这一句是必须的**，它让 MusicBridge 知道「Dart 起来了，可以
        // 往这儿推了」；不插的话事件只会一直往 pending 里攒，界面永远不动。
        //
        // 用 applicationContext 的理由和上面 AppUsageChannel 一样：读媒体会话
        // 不碰界面，没理由拿着 Activity 的引用多活一会儿（何况 MusicListenerService
        // 是个系统服务，它活得比这个 Activity 长得多）。
        val m = MusicChannel(applicationContext)
        music = m
        val musicChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MusicChannel.CHANNEL,
        )
        musicChannel.setMethodCallHandler { call, result -> m.handle(call, result) }
        MusicBridge.attach(musicChannel)
    }

    // launchMode 是 singleTop：App 已经开着的时候再分享一次，走的是这里，
    // 不会重新 onCreate。不接的话症状是「第一次分享有反应，第二次没有」。
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        share.onNewIntent(intent)
    }

    // 日历权限是异步申请的，结果得转回 CalendarChannel 挂起的那个 result
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (calendar?.onPermissionResult(requestCode, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun startRecording(result: MethodChannel.Result) {
        if (isRecording.get()) {
            result.success(null) // 已在录音
            return
        }
        val dir = cacheDir
        val file = File(dir, "stt_voice.wav")
        val bufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (bufferSize <= 0) {
            result.error("RECORD", "无法获取录音缓冲区大小", null)
            return
        }
        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize
            )
        } catch (e: Exception) {
            result.error("RECORD", "初始化录音失败: ${e.message}", null)
            return
        }

        try {
            recorder.startRecording()
        } catch (e: Exception) {
            recorder.release()
            result.error("RECORD", "启动录音失败: ${e.message}", null)
            return
        }

        audioRecord = recorder
        recordFile = file
        isRecording.set(true)

        // 后台线程持续读 PCM 数据写入文件
        Thread {
            val out = FileOutputStream(file)
            val buf = ByteArray(bufferSize)
            try {
                while (isRecording.get()) {
                    val read = recorder.read(buf, 0, buf.size)
                    if (read > 0) {
                        out.write(buf, 0, read)
                    }
                }
                out.flush()
            } catch (e: IOException) {
                // 忽略：停止时会关闭
            } finally {
                try {
                    out.close()
                } catch (_: IOException) {}
            }
        }.start()

        result.success(file.absolutePath)
    }

    private fun stopRecording(result: MethodChannel.Result) {
        if (!isRecording.get()) {
            result.error("RECORD", "当前没有在录音", null)
            return
        }
        isRecording.set(false)
        val recorder = audioRecord
        val file = recordFile
        audioRecord = null
        recordFile = null

        try {
            recorder?.stop()
        } catch (_: Exception) {}
        recorder?.release()

        if (file == null || !file.exists() || file.length() < 1000) {
            result.error("RECORD", "录音太短，没有录到内容", null)
            return
        }

        // PCM → WAV（加 44 字节头）
        try {
            val pcm = file.readBytes()
            val wav = pcmToWav(pcm, SAMPLE_RATE)
            FileOutputStream(file).use { it.write(wav) }
            result.success(file.absolutePath)
        } catch (e: Exception) {
            result.error("RECORD", "转 WAV 失败: ${e.message}", null)
        }
    }

    private fun cancelRecording() {
        isRecording.set(false)
        try {
            audioRecord?.stop()
        } catch (_: Exception) {}
        audioRecord?.release()
        audioRecord = null
        recordFile?.delete()
        recordFile = null
    }

    private fun pcmToWav(pcm: ByteArray, sampleRate: Int): ByteArray {
        val dataSize = pcm.size
        val totalSize = 44 + dataSize
        val wav = ByteArray(totalSize)
        // RIFF header
        writeString(wav, 0, "RIFF")
        writeIntLE(wav, 4, totalSize - 8)
        writeString(wav, 8, "WAVE")
        // fmt chunk
        writeString(wav, 12, "fmt ")
        writeIntLE(wav, 16, 16)             // fmt chunk size
        writeShortLE(wav, 20, 1)            // PCM format
        writeShortLE(wav, 22, 1)            // mono
        writeIntLE(wav, 24, sampleRate)     // sample rate
        writeIntLE(wav, 28, sampleRate * 2) // byte rate
        writeShortLE(wav, 32, 2)            // block align
        writeShortLE(wav, 34, 16)           // bits per sample
        // data chunk
        writeString(wav, 36, "data")
        writeIntLE(wav, 40, dataSize)
        System.arraycopy(pcm, 0, wav, 44, dataSize)
        return wav
    }

    private fun writeString(buf: ByteArray, offset: Int, s: String) {
        val bytes = s.toByteArray(Charsets.US_ASCII)
        System.arraycopy(bytes, 0, buf, offset, bytes.size)
    }

    private fun writeIntLE(buf: ByteArray, offset: Int, value: Int) {
        buf[offset] = (value and 0xFF).toByte()
        buf[offset + 1] = ((value shr 8) and 0xFF).toByte()
        buf[offset + 2] = ((value shr 16) and 0xFF).toByte()
        buf[offset + 3] = ((value shr 24) and 0xFF).toByte()
    }

    private fun writeShortLE(buf: ByteArray, offset: Int, value: Int) {
        buf[offset] = (value and 0xFF).toByte()
        buf[offset + 1] = ((value shr 8) and 0xFF).toByte()
    }

    override fun onDestroy() {
        cancelRecording()
        // FlutterActivity 默认会把引擎一起销毁，销毁之后那条 MethodChannel 就
        // 是死的了。不断开的话，MusicListenerService 那边推事件时会往一个死
        // 引擎里 invokeMethod——而那个服务是系统托管的，**可能在 Activity 没了
        // 之后还活着**。断开之后事件退回 pending 攒着，下次开 App 一并取走。
        // （这也是为什么 MusicBridge 要同时有「推」和「取」两条路。）
        MusicBridge.detach()
        music = null
        super.onDestroy()
    }
}
