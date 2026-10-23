# Privacy

ReKap processes recordings and exports locally. The native app has no analytics,
crash reporting service, account system, plugin runtime or automatic uploads.

macOS requests screen recording permission to capture the display, window or
region you select. Microphone access is requested only when you enable microphone
recording. System audio is included only when its recording option is enabled;
window capture records audio from that window's app. Permissions can be revoked
in System Settings → Privacy & Security.

Recordings and recovery segments are saved to your chosen recording folder
(default `~/Movies/ReKap/`). History is stored in
`~/Library/Application Support/ReKap/library.json`; preferences use macOS user
defaults. Imported videos stay in their original locations. Removing an entry
from history does not delete the recording or its recovery segments. Delete files
in Finder when you want to remove the media itself.

Exports use the bundled FFmpeg helper. Temporary export files and encoder error
logs are removed when the export finishes, fails or is cancelled. An unexpected
process termination can leave temporary files. Copy places an exported file on
the macOS clipboard; Open and Open With pass it to the application you choose.
Those applications and the destination folder's sync settings determine whether
the file subsequently leaves your Mac.
