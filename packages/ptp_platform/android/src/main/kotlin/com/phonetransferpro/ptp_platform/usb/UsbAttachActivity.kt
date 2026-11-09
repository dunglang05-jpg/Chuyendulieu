// Invisible activity for USB_DEVICE_ATTACHED / USB_ACCESSORY_ATTACHED (device test 2026-11-09: the system sheet
// "Chọn ứng dụng cho thiết bị USB" offered only MTP host / Photos). When the user picks "Chuyển dữ liệu" there, Android
// grants this app the USB permission for that device/accessory; [UsbTransport]'s polling then finds it with
// hasPermission() == true. This activity only brings the app back to the front. NOT TESTED ON DEVICES.
package com.phonetransferpro.ptp_platform.usb

import android.app.Activity
import android.content.Intent
import android.os.Bundle

class UsbAttachActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            packageManager.getLaunchIntentForPackage(packageName)?.let {
                it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                startActivity(it)
            }
        } catch (_: Exception) {
        }
        finish()
    }
}
