package dev.etornam.object_talk

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Rect
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.subject.SubjectSegmentation
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenterOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val segmenter by lazy {
        SubjectSegmentation.getClient(
            SubjectSegmenterOptions.Builder()
                .enableMultipleSubjects(
                    SubjectSegmenterOptions.SubjectResultOptions.Builder().enableSubjectBitmap().build(),
                )
                .build(),
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "object_talk/subject")
            .setMethodCallHandler { call, result ->
                if (call.method != "lift") return@setMethodCallHandler result.notImplemented()
                val bytes = call.argument<ByteArray>("image")
                    ?: return@setMethodCallHandler result.error("ARGS", "image is required", null)
                lift(bytes, call.argument<List<Double>>("box"), result)
            }
    }

    /**
     * Lifts the scanned object out of the frame with ML Kit subject
     * segmentation. Replies with a full-size PNG where everything but the
     * subject is transparent, or null when no subject is found.
     * [box] is [top, left, bottom, right], normalised with y from the top.
     */
    private fun lift(bytes: ByteArray, box: List<Double>?, result: MethodChannel.Result) {
        val frame = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: return result.error("DECODE", "could not decode image", null)
        segmenter.process(InputImage.fromBitmap(frame, 0))
            .addOnSuccessListener { segmentation ->
                val subjects = segmentation.subjects.filter { it.bitmap != null }
                if (subjects.isEmpty()) return@addOnSuccessListener result.success(null)
                // Keep subjects overlapping the middle of Gemini's box, so the
                // named object is lifted and not the couch it sits on.
                val picked = box?.takeIf { it.size == 4 }?.let { b ->
                    val (top, left, bottom, right) = b
                    val inner = Rect(
                        ((left + (right - left) * 0.2) * frame.width).toInt(),
                        ((top + (bottom - top) * 0.2) * frame.height).toInt(),
                        ((left + (right - left) * 0.8) * frame.width).toInt(),
                        ((top + (bottom - top) * 0.8) * frame.height).toInt(),
                    )
                    subjects.filter {
                        Rect.intersects(inner, Rect(it.startX, it.startY, it.startX + it.width, it.startY + it.height))
                    }
                }?.takeIf { it.isNotEmpty() } ?: subjects

                val out = Bitmap.createBitmap(frame.width, frame.height, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(out)
                picked.forEach { canvas.drawBitmap(it.bitmap!!, it.startX.toFloat(), it.startY.toFloat(), null) }
                val png = ByteArrayOutputStream()
                out.compress(Bitmap.CompressFormat.PNG, 100, png)
                result.success(png.toByteArray())
            }
            // Segmentation is polish: the Dart side falls back to a plain crop.
            .addOnFailureListener { result.success(null) }
    }
}
