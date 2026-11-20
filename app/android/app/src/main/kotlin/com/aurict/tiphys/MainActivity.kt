package com.aurict.tiphys

import android.view.KeyEvent
import com.aurict.tiphys_native.VelourMedia
import io.flutter.embedding.android.FlutterFragmentActivity

// local_auth (fingerprint) requires a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    // While the Velour remote is open, the volume buttons change the PC's Velour volume instead of the phone's.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean = VelourMedia.onKey(event) || super.dispatchKeyEvent(event)
}
