package com.valdo.jeep_obd2

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val spp = SppBridge()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        spp.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }

    override fun onDestroy() {
        spp.close()
        super.onDestroy()
    }
}
