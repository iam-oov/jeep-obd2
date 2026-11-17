package com.valdo.jeep_obd2

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * Bluetooth Classic SPP (RFCOMM) sin exigir emparejamiento.
 *
 * Muchos clones ELM327 no se dejan emparejar desde Ajustes, pero aceptan un
 * socket RFCOMM "inseguro" (sin bond). Se prueban, en orden:
 *   1. createInsecureRfcommSocketToServiceRecord(SPP)
 *   2. createRfcommSocketToServiceRecord(SPP)   (seguro: puede pedir PIN)
 *   3. createInsecureRfcommSocket(1) por reflexión (canal 1 directo, sin SDP)
 *
 * Canales:
 *   jeep_obd2/spp        connect(address) -> método usado, write(bytes), close()
 *   jeep_obd2/spp/input  eventos {id, data: ByteArray} o {id, closed: true}
 */
@SuppressLint("MissingPermission")
class SppBridge : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val spp: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private val main = Handler(Looper.getMainLooper())
    private val writer = Executors.newSingleThreadExecutor()
    private var adapter: BluetoothAdapter? = null
    private var sink: EventChannel.EventSink? = null

    @Volatile private var socket: BluetoothSocket? = null
    @Volatile private var connectionId = 0

    fun attach(messenger: BinaryMessenger, context: Context) {
        adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        MethodChannel(messenger, "jeep_obd2/spp").setMethodCallHandler(this)
        EventChannel(messenger, "jeep_obd2/spp/input").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connect" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("bad_args", "Falta address", null)
                    return
                }
                thread(name = "spp-connect") {
                    try {
                        val (id, method) = connectBlocking(address)
                        main.post { result.success(mapOf("id" to id, "method" to method)) }
                    } catch (e: Exception) {
                        main.post { result.error("connect_failed", e.message, null) }
                    }
                }
            }
            "write" -> {
                val bytes = call.argument<ByteArray>("data")
                val s = socket
                if (bytes == null || s == null) {
                    result.error("not_connected", "No hay conexión", null)
                    return
                }
                writer.execute {
                    try {
                        s.outputStream.write(bytes)
                        s.outputStream.flush()
                        main.post { result.success(null) }
                    } catch (e: IOException) {
                        main.post { result.error("write_failed", e.message, null) }
                    }
                }
            }
            "close" -> {
                close()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun connectBlocking(address: String): Pair<Int, String> {
        val bt = adapter ?: throw IOException("Este teléfono no tiene Bluetooth")
        close()
        bt.cancelDiscovery()
        val device: BluetoothDevice = bt.getRemoteDevice(address)

        val attempts: List<Pair<String, () -> BluetoothSocket>> = listOf(
            "inseguro" to { device.createInsecureRfcommSocketToServiceRecord(spp) },
            "seguro" to { device.createRfcommSocketToServiceRecord(spp) },
            "canal 1" to {
                device.javaClass
                    .getMethod("createInsecureRfcommSocket", Int::class.javaPrimitiveType)
                    .invoke(device, 1) as BluetoothSocket
            },
        )

        val errors = mutableListOf<String>()
        for ((name, make) in attempts) {
            var s: BluetoothSocket? = null
            try {
                s = make()
                s.connect()
                val id = ++connectionId
                socket = s
                startReader(s, id)
                return id to name
            } catch (e: Exception) {
                errors.add("$name: ${e.cause?.message ?: e.message}")
                try { s?.close() } catch (_: IOException) {}
            }
        }
        throw IOException(errors.joinToString("; "))
    }

    private fun startReader(s: BluetoothSocket, id: Int) {
        thread(name = "spp-reader-$id") {
            val buffer = ByteArray(1024)
            try {
                while (true) {
                    val n = s.inputStream.read(buffer)
                    if (n < 0) break
                    val chunk = buffer.copyOf(n)
                    main.post { sink?.success(mapOf("id" to id, "data" to chunk)) }
                }
            } catch (_: IOException) {
                // socket cerrado
            }
            main.post { sink?.success(mapOf("id" to id, "closed" to true)) }
        }
    }

    fun close() {
        val s = socket
        socket = null
        try { s?.close() } catch (_: IOException) {}
    }
}
