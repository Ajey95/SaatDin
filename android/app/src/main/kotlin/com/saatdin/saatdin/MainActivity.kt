package com.saatdin.saatdin

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.telephony.CellIdentityCdma
import android.telephony.CellIdentityGsm
import android.telephony.CellIdentityLte
import android.telephony.CellIdentityNr
import android.telephony.CellIdentityTdscdma
import android.telephony.CellIdentityWcdma
import android.telephony.CellInfo
import android.telephony.CellInfoCdma
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoTdscdma
import android.telephony.CellInfoWcdma
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "saatdin/mobile_signal"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCellInfo" -> result.success(getCellInfo())
                    else -> result.notImplemented()
                }
            }
    }

    private fun getCellInfo(): Map<String, Any?> {
        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val telephonyManager =
            getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager

        val payload = mutableMapOf<String, Any?>(
            "capturedAtMs" to System.currentTimeMillis(),
            "transport" to activeTransport(connectivityManager),
            "carrier" to telephonyManager.networkOperatorName,
            "networkOperator" to telephonyManager.networkOperator,
            "simOperator" to telephonyManager.simOperator,
        )

        if (!hasLocationPermission()) {
            payload["permissionGranted"] = false
            return payload
        }

        payload["permissionGranted"] = true
        payload["dataNetworkType"] = telephonyManager.dataNetworkType
        payload["voiceNetworkType"] = telephonyManager.voiceNetworkType

        try {
            val cells = telephonyManager.allCellInfo.orEmpty()
                .mapNotNull { cell -> cellPayload(cell) }
                .take(4)
            if (cells.isNotEmpty()) {
                payload["cells"] = cells
            }
        } catch (_: SecurityException) {
            payload["permissionGranted"] = false
        } catch (_: Throwable) {
            // Best-effort signal capture; the Flutter side handles missing metadata.
        }

        return payload
    }

    private fun hasLocationPermission(): Boolean {
        val fine =
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_FINE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
        val coarse =
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun activeTransport(connectivityManager: ConnectivityManager): String {
        val network = connectivityManager.activeNetwork ?: return "offline"
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return "unknown"
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            else -> "other"
        }
    }

    private fun cellPayload(cellInfo: CellInfo): Map<String, Any?>? =
        when (cellInfo) {
            is CellInfoLte -> identityPayload(
                technology = "lte",
                registered = cellInfo.isRegistered,
                dbm = cellInfo.cellSignalStrength.dbm,
                identity = cellInfo.cellIdentity,
            )
            is CellInfoGsm -> identityPayload(
                technology = "gsm",
                registered = cellInfo.isRegistered,
                dbm = cellInfo.cellSignalStrength.dbm,
                identity = cellInfo.cellIdentity,
            )
            is CellInfoWcdma -> identityPayload(
                technology = "wcdma",
                registered = cellInfo.isRegistered,
                dbm = cellInfo.cellSignalStrength.dbm,
                identity = cellInfo.cellIdentity,
            )
            is CellInfoTdscdma -> identityPayload(
                technology = "tdscdma",
                registered = cellInfo.isRegistered,
                dbm = cellInfo.cellSignalStrength.dbm,
                identity = cellInfo.cellIdentity,
            )
            is CellInfoNr -> identityPayload(
                technology = "nr",
                registered = cellInfo.isRegistered,
                dbm = cellInfo.cellSignalStrength.dbm,
                identity = cellInfo.cellIdentity,
            )
            is CellInfoCdma -> {
                val identity = cellInfo.cellIdentity
                mapOf(
                    "technology" to "cdma",
                    "registered" to cellInfo.isRegistered,
                    "dbm" to cellInfo.cellSignalStrength.dbm,
                    "networkId" to identity.networkId,
                    "systemId" to identity.systemId,
                    "basestationId" to identity.basestationId,
                )
            }
            else -> null
        }

    private fun identityPayload(
        technology: String,
        registered: Boolean,
        dbm: Int,
        identity: Any,
    ): Map<String, Any?> {
        val payload = mutableMapOf<String, Any?>(
            "technology" to technology,
            "registered" to registered,
            "dbm" to dbm,
        )

        when (identity) {
            is CellIdentityLte -> {
                payload["ci"] = identity.ci
                payload["pci"] = identity.pci
                payload["tac"] = identity.tac
                payload["earfcn"] = identity.earfcn
                payload["mcc"] = identity.mccString
                payload["mnc"] = identity.mncString
            }
            is CellIdentityGsm -> {
                payload["cid"] = identity.cid
                payload["lac"] = identity.lac
                payload["arfcn"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) identity.arfcn else null
                payload["mcc"] = identity.mccString
                payload["mnc"] = identity.mncString
            }
            is CellIdentityWcdma -> {
                payload["cid"] = identity.cid
                payload["lac"] = identity.lac
                payload["psc"] = identity.psc
                payload["uarfcn"] = identity.uarfcn
                payload["mcc"] = identity.mccString
                payload["mnc"] = identity.mncString
            }
            is CellIdentityTdscdma -> {
                payload["cid"] = identity.cid
                payload["lac"] = identity.lac
                payload["cpid"] = identity.cpid
                payload["uarfcn"] = identity.uarfcn
                payload["mcc"] = identity.mccString
                payload["mnc"] = identity.mncString
            }
            is CellIdentityNr -> {
                payload["nci"] = identity.nci
                payload["pci"] = identity.pci
                payload["tac"] = identity.tac
                payload["nrarfcn"] = identity.nrarfcn
                payload["mcc"] = identity.mccString
                payload["mnc"] = identity.mncString
            }
            is CellIdentityCdma -> {
                payload["networkId"] = identity.networkId
                payload["systemId"] = identity.systemId
                payload["basestationId"] = identity.basestationId
            }
        }

        return payload
    }
}
