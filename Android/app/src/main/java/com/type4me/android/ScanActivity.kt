package com.type4me.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.view.View
import android.widget.FrameLayout
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.ViewModel
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.type4me.android.data.PendingImport
import com.type4me.android.data.TransferAssembler
import com.type4me.android.data.TransferException
import com.type4me.android.databinding.ActivityScanBinding
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Scans the codes the Mac shows on its Mobile page.
 *
 * A large sync is split into several codes that the Mac cycles through, so
 * decoding runs continuously until every part is in. ZXing is fed raw camera
 * frames; the Mac's codes are plain QR, which keeps the dependency small.
 */
class ScanActivity : AppCompatActivity() {

    private lateinit var binding: ActivityScanBinding
    private val scanModel: ScanViewModel by viewModels()
    private var cameraProvider: ProcessCameraProvider? = null
    private var analyzer: ExecutorService? = null
    private var lastDecodeAt = 0L

    private val requestCamera = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            binding.permissionPanel.visibility = View.GONE
            startCamera()
        } else {
            showPermissionPanel(
                blocked = !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA),
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        binding = ActivityScanBinding.inflate(layoutInflater)
        setContentView(binding.root)
        applyInsets()

        binding.close.setOnClickListener { finish() }
        binding.grantCamera.setOnClickListener {
            requestCamera.launch(Manifest.permission.CAMERA)
        }
        binding.openSettings.setOnClickListener {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                ),
            )
        }
        intent.getStringExtra(EXTRA_SEED)?.let(::handle)
        if (scanModel.imported) return

        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.CAMERA,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            startCamera()
        } else {
            requestCamera.launch(Manifest.permission.CAMERA)
        }
    }

    private fun applyInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val margin = (16 * resources.displayMetrics.density).toInt()
            (binding.close.layoutParams as? FrameLayout.LayoutParams)?.let {
                it.topMargin = bars.top + margin
                it.marginEnd = bars.right + margin
                binding.close.layoutParams = it
            }
            (binding.statusCard.layoutParams as? FrameLayout.LayoutParams)?.let {
                it.bottomMargin = bars.bottom + margin * 2
                binding.statusCard.layoutParams = it
            }
            insets
        }
    }

    private fun showPermissionPanel(blocked: Boolean) {
        binding.permissionPanel.visibility = View.VISIBLE
        binding.permissionText.setText(R.string.scan_needs_camera)
        binding.openSettings.visibility = if (blocked) View.VISIBLE else View.GONE
    }

    private fun showUnavailable() {
        binding.scanStatus.setText(R.string.scan_camera_unavailable)
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = runCatching { future.get() }.getOrNull()
            if (provider == null) {
                showUnavailable()
                return@addListener
            }
            cameraProvider = provider
            val preview = Preview.Builder().build().apply {
                surfaceProvider = binding.preview.surfaceProvider
            }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            val executor = Executors.newSingleThreadExecutor()
            analyzer = executor
            analysis.setAnalyzer(executor) { image -> analyze(image) }
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                    analysis,
                )
            }.onFailure { showUnavailable() }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun analyze(image: ImageProxy) {
        try {
            if (scanModel.imported) return
            val now = SystemClock.elapsedRealtime()
            if (now - lastDecodeAt < 120) return
            lastDecodeAt = now
            val text = decode(image) ?: return
            runOnUiThread { handle(text) }
        } finally {
            image.close()
        }
    }

    private fun decode(image: ImageProxy): String? {
        val plane = image.planes.firstOrNull() ?: return null
        val width = image.width
        val height = image.height
        if (width <= 0 || height <= 0) return null
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val buffer = plane.buffer
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        val luminance = if (pixelStride == 1 && rowStride == width) {
            bytes
        } else {
            ByteArray(width * height).also { output ->
                for (row in 0 until height) {
                    val sourceBase = row * rowStride
                    val targetBase = row * width
                    for (column in 0 until width) {
                        val index = sourceBase + column * pixelStride
                        if (index < bytes.size) output[targetBase + column] = bytes[index]
                    }
                }
            }
        }
        // QR detection is rotation independent; the detector finds the finder
        // patterns in any orientation, so the frame is used as it arrives.
        val source: LuminanceSource = PlanarYUVLuminanceSource(
            luminance,
            width,
            height,
            0,
            0,
            width,
            height,
            false,
        )
        val bitmap = BinaryBitmap(HybridBinarizer(source))
        val hints = mapOf(
            DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
            DecodeHintType.TRY_HARDER to true,
            DecodeHintType.CHARACTER_SET to "UTF-8",
        )
        return runCatching {
            MultiFormatReader().apply { setHints(hints) }.decodeWithState(bitmap)?.text
        }.getOrNull()
    }

    private fun handle(text: String) {
        if (scanModel.imported) return
        when (val status = scanModel.accept(text)) {
            is TransferAssembler.Status.Ignored -> Unit

            is TransferAssembler.Status.Progress -> {
                binding.scanStatus.text = getString(
                    R.string.scan_progress,
                    status.received.size,
                    status.total,
                )
            }

            is TransferAssembler.Status.Failed -> {
                binding.scanStatus.setText(
                    if (status.error.kind == TransferException.Kind.UNSUPPORTED_VERSION) {
                        R.string.scan_unsupported_version
                    } else {
                        R.string.scan_failed
                    },
                )
            }

            is TransferAssembler.Status.Complete -> {
                scanModel.markImported()
                PendingImport.payload = status.payload
                startActivity(Intent(this, ImportActivity::class.java))
                finish()
            }
        }
    }

    override fun onDestroy() {
        analyzer?.shutdownNow()
        analyzer = null
        cameraProvider?.unbindAll()
        cameraProvider = null
        super.onDestroy()
    }

    companion object {
        const val EXTRA_SEED = "seed"
    }
}

/**
 * Holds the partially received payload across configuration changes, so
 * rotating mid multi-code scan does not discard the parts already scanned.
 */
class ScanViewModel : ViewModel() {
    private val assembler = TransferAssembler()

    /** True once this payload has been handed to [ImportActivity]. */
    @Volatile
    var imported = false
        private set

    fun accept(text: String): TransferAssembler.Status = assembler.add(text)

    fun markImported() {
        imported = true
    }
}
