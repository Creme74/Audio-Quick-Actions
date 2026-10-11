<p align="center">
  <img src="Docs/nagra.png" width="360" alt="Nagra IV-S tape recorder">
</p>

# Audio Quick Actions

A small collection of macOS Finder Quick Actions for music producers and sound designers. Select your audio files in the Finder, right-click, pick a Quick Action — that's it.

| Quick Action | What it does |
|---|---|
| [Normalize Peak](#normalize-peak) | Peak-normalizes lossless audio files without losing their metadata (Apple Loops tags included). |
| [Normalize Loudness](#normalize-loudness) | Brings lossless audio files to a target loudness (Spotify, Apple Music, YouTube, broadcast or your own value), with a plain, transparent gain change. |
| [Analyze Loudness](#analyze-loudness) | Measures the loudness (LUFS) and true peak of any audio file, and shows what each streaming platform would do with it. |

---

## Requirements

- macOS (tested on macOS 14 Sonoma, Apple Silicon and Intel)
- [Homebrew](https://brew.sh), then in Terminal:

  ```bash
  brew install sox_ng ffmpeg
  ```

| | `sox_ng` | `ffmpeg` |
|---|---|---|
| Normalize Peak | WAV, AIFF, CAF | FLAC only |
| Normalize Loudness | WAV, AIFF, CAF | always (measurement and FLAC) |
| Analyze Loudness | — | always |

The classic `sox` formula works too.

## Download & installation

1. Download the Quick Action you want from the **[Releases](https://github.com/Creme74/Audio-Quick-Actions/releases/latest)** page and unzip it:
   - [Normalize-Peak.zip](https://github.com/Creme74/Audio-Quick-Actions/releases/latest/download/Normalize-Peak.zip)
   - [Normalize-Loudness.zip](https://github.com/Creme74/Audio-Quick-Actions/releases/latest/download/Normalize-Loudness.zip)
   - [Analyze-Loudness.zip](https://github.com/Creme74/Audio-Quick-Actions/releases/latest/download/Analyze-Loudness.zip)
2. Double-click the `.workflow` file and click **Install**.
3. If it doesn't show up in the Finder's right-click menu, open **System Settings**, search for **Extensions**, go to **Finder** and tick it.

To use it: select one or more audio files in the Finder, then right-click → **Quick Actions** → the Quick Action.

---

## Normalize Peak

Normalizes the peak level of your audio files to the level you choose, while keeping everything else exactly as it was.

<p align="center">
  <img src="Docs/normalize-peak-screenshot.png" width="480" alt="Normalize Peak window">
</p>

### Features

- **Choose your target level**: 0 dB, -0.1 dB, -0.2 dB, -0.5 dB or -1 dB
- **Overwrite or Duplicate**: replace the original files, or create normalized copies in a `Normalized` subfolder next to the originals (same file names)
- **Metadata stays intact**: for WAV, AIFF and CAF files, only the audio samples are rewritten. Apple Loops information (tempo, key, tags, transients), markers, ID3 tags, Finder tags and Spotlight comments are all preserved
- **Same format, same resolution**: a 16-bit / 44.1 kHz WAV stays a 16-bit / 44.1 kHz WAV. Bit depth (8, 16, 24, 32-bit integer or float) and sample rate never change
- **Lossless formats only**: WAV, AIFF / AIF / AIFC, CAF (uncompressed) and FLAC. Lossy files (MP3, AAC/M4A…) are skipped and listed at the end
- **Smart**: files already at the requested level are not processed again
- **Fast**: several files are processed in parallel

### Good to know

- **16-bit files** get a light TPDF dither when the gain is applied, which is the standard way to avoid quantization distortion.
- **Already normalized files**: if a file's peak is within 0.01 dB of the target, its audio is left untouched, but its modification date is updated like the others. In Duplicate mode it is still copied, so the `Normalized` folder is always complete.
- **Overwrite cannot be undone.** Use Duplicate if you want to keep your originals.

### Customization

The settings are at the top of the script (open the workflow in Automator to edit it):

```zsh
levels=(0 -0.1 -0.2 -0.5 -1)   # target peak levels offered, in dBFS
default_level=0
tolerance=0.01                 # dB: files this close to the target are left as is
copydir="Normalized"           # subfolder used by "Duplicate"
```

[`Normalize Peak/normalize-peak.sh`](Normalize%20Peak/normalize-peak.sh) is a readable copy of the script embedded in the workflow.

---

## Normalize Loudness

Measures the loudness of your audio files, shows the gain each one needs for the target you choose, then applies it — and nothing else.

<p align="center">
  <img src="Docs/normalize-loudness-screenshot.png" width="480" alt="Normalize Loudness window">
</p>

### Features

- **Measured like the streaming platforms**: integrated loudness (LUFS) and true peak (dBTP), with the ITU-R BS.1770 / EBU R128 method
- **Choose your target** in the menu: Spotify Normal -14, Spotify Loud -11, Spotify Quiet -19, YouTube -14, Apple Music -16, Tidal -14, Amazon Music -14, Deezer -15, SoundCloud -14, Broadcast EBU R128 -23 LUFS
- **Custom target**: pick **Custom…** at the bottom of the menu and type your own value (from -60 to 0 LUFS); the gains are updated as you type
- **See before you apply**: the gain and the resulting loudness are shown for every file, for the selected target
- **As transparent as possible**: a plain gain change — no compressor, no limiter, no EQ
- **Overwrite or Duplicate**, **metadata stays intact**, **same format, same resolution**, **lossless formats only**: exactly like Normalize Peak. Other files (MP3, AAC/M4A…) are measured and shown, but never modified

### Good to know

- **Quiet files with loud peaks**: loud files are always turned down to the target, but quiet files are only turned up until their true peak reaches -1 dBTP, so nothing clips. Such files may end up below the target; the window says *limited by true peak*. Reaching the target anyway would need a limiter, which would no longer be transparent.
- **Files already at the target** (0.0 dB gain): their audio is left untouched, only their modification date is updated (copied as is in Duplicate mode).
- **16-bit files** get a light TPDF dither when the gain is applied.
- **Overwrite cannot be undone.** Use Duplicate if you want to keep your originals.

### Customization

```zsh
targets=(                      # "Name:LUFS", the first one is selected by default
  "Spotify Normal:-14"
  ...
)
ceiling=-1                     # dBTP: quiet files are never turned up past this true peak
copydir="Normalized"           # subfolder used by "Duplicate"
```

[`Normalize Loudness/normalize-loudness.sh`](Normalize%20Loudness/normalize-loudness.sh) is a readable copy of the script embedded in the workflow.

---

## Analyze Loudness

Measures the loudness of your audio files and shows what each streaming platform would do with them. Nothing is modified.

<p align="center">
  <img src="Docs/analyze-loudness-screenshot.png" width="480" alt="Analyze Loudness window">
</p>

### Features

- **Any audio format** ffmpeg can read: WAV, AIFF, CAF, FLAC, ALAC, MP3, AAC/M4A…
- **Integrated loudness** (LUFS) and **true peak** (dBTP), with the ITU-R BS.1770 / EBU R128 method
- **Platform menu**: the gain Spotify (Normal, Loud, Quiet), YouTube, Apple Music, Tidal, Amazon Music, Deezer, SoundCloud or a broadcast EBU R128 delivery would apply to each file, track by track, with notes such as *not turned up*, *limited by true peak* or *limiter*
- **Several files at once**: the results are listed under each file name, and one menu switches the platform for all of them
- **Copy to Clipboard**: file name, loudness, true peak and the result for the selected platform

### Good to know

Spotify's targets and rules come from its official documentation. The other platforms' values are the ones commonly reported; they are not always officially published and may change.

[`Analyze Loudness/analyze-loudness.sh`](Analyze%20Loudness/analyze-loudness.sh) is a readable copy of the script embedded in the workflow.

---

## Uninstall

Delete the `.workflow` file from `~/Library/Services`.

## License

This project is distributed under the **GPL-3.0-or-later** license — see [LICENSE](LICENSE).

## Author

Made by **Nicolas Scaravilli** (Kid Creme)

- [Bandcamp](https://kidcreme.bandcamp.com/)
- [Spotify](https://open.spotify.com/artist/21LRoheW1z49N5d52wlQ5X)
