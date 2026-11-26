package app.otpanda.fixture

import android.app.PendingIntent
import android.content.Intent
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CredentialEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import androidx.credentials.provider.PublicKeyCredentialEntry

/**
 * DEBUG-ONLY synthetic credential provider for the lock-prompt runtime fixture. It answers a public-key get request with ONE fake entry whose selection
 * returns a synthetic assertion signed by a throwaway in-memory key (see SyntheticAssertionActivity). No real account, seed, user key or server is involved.
 * It proves only this fixture provider (not Google Password Manager, Samsung or any hardware path). Lives in the debug source set only.
 */
class SyntheticProviderService : CredentialProviderService() {
    override fun onBeginGetCredentialRequest(request: BeginGetCredentialRequest, cancellationSignal: CancellationSignal,
                                             callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>) {
        val entries = mutableListOf<CredentialEntry>()
        android.util.Log.i("LOCKFX", "ev=provider_begin_get options=${request.beginGetCredentialOptions.size}")
        for (o in request.beginGetCredentialOptions) {
            if (o is BeginGetPublicKeyCredentialOption) {
                val pi = PendingIntent.getActivity(applicationContext, 1, Intent(SyntheticAssertionActivity.ACTION).setPackage(packageName),
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                entries.add(PublicKeyCredentialEntry(context = applicationContext, username = "synthetic-fixture-user", pendingIntent = pi,
                    beginGetPublicKeyCredentialOption = o, displayName = "Synthetic fixture passkey"))
            }
        }
        callback.onResult(BeginGetCredentialResponse(entries))
    }
    override fun onBeginCreateCredentialRequest(request: BeginCreateCredentialRequest, cancellationSignal: CancellationSignal,
                                                callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>) {
        callback.onError(androidx.credentials.exceptions.CreateCredentialUnsupportedException("fixture provider does not create"))
    }
    override fun onClearCredentialStateRequest(request: ProviderClearCredentialStateRequest, cancellationSignal: CancellationSignal,
                                               callback: OutcomeReceiver<Void?, ClearCredentialException>) {
        callback.onResult(null)
    }
}
