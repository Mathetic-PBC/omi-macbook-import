# omi-macbook-import

Two apps that keep what an [Omi](https://github.com/BasedHardware/omi)
pendant records on a Mac you own, with nobody's server in between.

- **Omi Relay**, on the iPhone, takes the audio off the pendant over
  Bluetooth and sends each finished recording straight to the Mac.
- **Omi Import**, on the Mac, is where recordings are kept: a folder you
  choose, an audio file and a note for each, in
  [Engelbart](https://github.com/Mathetic-PBC/engelbart-canvas)'s library by
  reference.

The Mac never talks to the pendant. The pendant gives each recording to one
device only, so one device takes them, and that is the phone, which is
carried with it.

- **Files.** Each recording is two files in a folder for its day: the audio,
  as the pendant encoded it, in an Ogg Opus file (`.opus`, about 14 MB an
  hour), and a short markdown note with when it started, how long it is and
  a link to the audio.
- **Phone to Mac.** The phone finds the Mac on the same Wi-Fi and sends over
  a connection encrypted with a pairing code typed in once. A recording stays
  on the phone until the Mac has confirmed it, then the phone's copy is
  deleted.
- **Omi's cloud.** What the official Omi app took off the pendant earlier is
  in Omi's cloud. With a developer key, each of those conversations is copied
  into the same folder as a markdown note: title, summary, action items and
  the transcript with speakers. The cloud is checked when the Mac starts or
  wakes and every half hour.
- **Engelbart.** If Engelbart is on the Mac, setup asks whether to add the
  folder to its library. It is added once, as a folder, by reference:
  Engelbart lists what is in it live, so every later recording is in reach
  from the `@` menu and nothing is copied into Engelbart.

## Install

Needs macOS 14 or later, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The phone app needs iOS 17 and an Apple developer
team.

**The Mac app**

    make install

builds it, copies it to `/Applications/OmiImport.app` and opens it. A
waveform appears in the menu bar and the setup window opens.

**The phone app**

    make phone-install DEVICE="<your iPhone>"     # straight onto the phone
    make testflight                               # or through TestFlight

`xcrun devicectl list devices` gives the name for `DEVICE`. `make testflight`
archives the app and uploads it; the app has to exist in App Store Connect
first, with the bundle identifier `com.mathetic.OmiRelay`, and Xcode has to
be signed in to the team. The first signed build registers that identifier
with the team.

## Set up

On the Mac:

1. **Choose a folder.** **Choose…** picks one, **New Folder…** makes one,
   called `Omi` unless you rename it. Both start in `~/personal` when there
   is one, else in the home folder.
2. **Engelbart.** When Engelbart is installed, the app asks whether to add
   the folder to its library. Engelbart keeps its library in a database that
   only one program may have open, so the folder is added while Engelbart is
   closed: at once if it is, otherwise the next time it quits, or straight
   away with **Quit Engelbart and Add**, which opens it again afterwards.
3. **Your phone.** Setup shows a pairing code. macOS may ask once whether
   Omi Import may find devices on the local network, and the firewall
   whether it may accept connections; both need a yes.
4. **Omi's cloud** (optional). Make a key at [app.omi.me/developers](https://app.omi.me/developers)
   with the `conversations:read` scope, paste it in and click **Connect**.
   The key is kept in the login keychain. The first check walks the whole
   history; Omi allows 25 transcript requests an hour, so a long history
   comes in over a few hours.
5. **Open at login,** so the Mac is listening whenever it is on.

On the phone:

1. Remove the official Omi app, or sign out of it. Left running, it takes
   recordings off the pendant too, and those never reach the Mac.
2. Open Omi Relay with the pendant on and nearby, and allow Bluetooth. The
   first Omi found is remembered; swipe its row to forget it.
3. Type the Mac's pairing code and allow Local Network access.
4. Optional: the Mac's address for when the two aren't on one network, such
   as its name on a VPN you run. Without it, recordings wait on the phone
   until the Mac is on the same Wi-Fi.

## How it works

**Taking audio off the pendant.** The phone stays connected to the pendant.
On connecting it copies what the pendant stored while the phone was away, a
window at a time: each window is written to a journal and synced to disk
before the pendant is told it may free it. It asks again every five minutes.
What happens in between depends on the firmware. Before 3.0.24 a pendant
stores nothing while something is connected to it, so the phone listens
live and keeps what it hears. From 3.0.24 it stores while connected, and
everything comes from storage. [docs/protocol.md](docs/protocol.md) has the
protocol and where each part was read from.

**In the background.** iOS runs a backgrounded app only when Bluetooth has
something for it. The pendant reports its battery every five seconds while
connected, which is enough to keep the phone app finishing recordings and
sending them. If iOS closes the app, it starts it again when the pendant
next has something to say. Swiping the app away stops that until it is
opened again; the pendant keeps recording to its own storage meanwhile.

**Recordings.** The pendant stores one unbroken run of audio with a time on
every 444 bytes, and its microphone sleeps through silence. A recording ends
where the times jump by more than a minute, which is the official app's
rule. A recording is written once it has been quiet for a minute.

**Phone to Mac.** The Mac listens on port 47843 and announces itself over
Bonjour as `_omi-import._tcp`. For each recording the phone says what it is
(start, length, size, SHA-256), the Mac answers "send it" or "I have that
one", the phone sends the bytes, and the Mac checks the hash, puts the file
in place, syncs it to disk and replies with a receipt. Only then does the
phone delete its copy. The connection is TLS keyed by the pairing code, so
a device without the code can neither send nor read.

    Omi/
      2026-11-23/
        2026-11-23 14-05-12.opus    the audio, as the pendant encoded it
        2026-11-23 14-05-12.md      when, how long, a link to the audio
      .omi-import/                  the list of what is held

**Omi's cloud.** The Developer API's `GET /v1/dev/user/conversations` gives
conversations newest first, with transcripts on request. The app walks back
through them a page at a time, each page starting at the oldest
conversation of the one before, and saves where it got to after every page.
After that, each check looks again at the last day, since a conversation
appears once Omi has processed it and its summary and speaker names can
change for a while. A conversation is one note, named for when it began and
its title, and is written again only when the cloud's copy changed and the
note is still as the app wrote it: a note you wrote in is left alone, and
one you deleted stays deleted. The API gives no audio.

    Omi/
      2026-11-22/
        2026-11-22 18-30-05 Dinner plans.md

**The clock.** The pendant has no clock of its own and the phone is the
only thing that sets it. After the pendant restarts away from the phone its
times run early by however long it was off. The phone measures that on
connecting, sets the clock, and corrects the times of what was recorded in
between. A recording whose time was corrected, or couldn't be, says so in
its note.

**Engelbart.** Engelbart's library is a table with one row per item, in a
PGlite database at `~/.engelbart/library.pglite`. The app adds one row, of
type `folder`, pointing at the import folder, using the copy of PGlite
inside Engelbart.app. It checks first whether any process has the database
open, and refuses if one does. Engelbart doesn't list audio files, which
is what the markdown note beside each recording is for. Engelbart lists
folders only inside the home folder; setup says so if the chosen folder is
elsewhere.

## Limits

- Neither app has met a real pendant or a real iPhone. The pendant side was
  written from the firmware's source and tested against a simulated
  pendant; the phone-to-Mac transfer was tested between two processes on
  one Mac; the phone app was run in the iOS simulator, which has no
  Bluetooth.
- Firmware 3.0.20 or later for stored audio. On firmware before 3.0.24 the
  pendant frees audio as it sends it, so a connection that drops mid-copy
  loses the couple of seconds that were in the air, and audio heard live
  that the radio drops is gone. The phone's log counts the second.
- Audio from the pendant comes with no transcript and no speaker names:
  with the official app out of the way, nothing is transcribing it yet.
  Conversations from Omi's cloud come with a transcript and no audio.
- The phone sends only while iOS lets it run, and only when it can reach
  the Mac. Until then recordings wait on the phone.
- The pairing code is the only key. Traffic recorded today can be read by
  someone who gets the code later; **New Code…** on the Mac replaces it.
- The cloud side was tested against a stand-in server written from the
  API's documentation and the backend's source, not against Omi's own.

## Develop

    make test     # the Core package's tests
    make debug    # a debug build of the Mac app, with its own bundle identifier
    make phone    # compiles the phone app for a device, unsigned

`Core/` is a Swift package both apps use: the pendant's protocol, the
journal, recordings, the phone-to-Mac transfer and the cloud walk.

A debug build of the Mac app refuses to run without `OMI_IMPORT_HOME`, a
folder of its own for settings, so it never touches the installed app's.
With `OMI_IMPORT_HEADLESS=1 OMI_IMPORT_SNAPSHOT=/path/to.png` it draws the
settings window into a PNG without showing anything on screen and quits. It
listens for a phone only when `OMI_IMPORT_PAIRING` and `OMI_IMPORT_PORT` are
set, and never announces itself. `OMI_HANDOFF_ENDPOINT=host:port` and
`OMI_HANDOFF_CODE` make the `testAgainstARunningMac` test send a recording
to it as the phone would.

A debug build of the phone app started with `OMI_RELAY_SAMPLE=1` shows a
filled-in screen and touches nothing.

## License

MIT
