# AI Haptics Flutter application

Windows / Android application for conversations, voice interaction, waveform
preview and supported DG-LAB device connections. See the repository root README
and docs/quick-start.md for setup, and docs/building.md for build requirements.

Native libraries are built from core/ and copied by scripts/build-windows.ps1
or scripts/build-android.ps1; they are intentionally not tracked in Git.
Run platform builds sequentially because they share an ASCII staging directory.

The public profile has no pilot login or bundled service credentials. Users can
import their own relay connection file, configure a supported API service, or
browse offline. The private pilot profile is configured outside the checkout.

Device output uses the supported gateway/Bluetooth adapters with explicit local
authorization and runtime limits. Imported waveform files can be previewed and
exported; only supported built-in waveforms are enabled for physical output.
No official DG-LAB application or firmware is distributed here.

Flutter-generated platform scaffold files retain the Flutter BSD notices in
docs/third-party. Project-specific application code is covered by the root MIT
license; see NOTICE.md for third-party exceptions.
