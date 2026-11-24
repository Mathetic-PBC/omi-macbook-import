# omi-macbook-import

Copies what an [Omi](https://github.com/BasedHardware/omi) pendant recorded
onto a Mac: straight off the pendant over Bluetooth, with no phone in
between, and from Omi's cloud for what the phone app already took. It puts
the folder it copies into in [Engelbart](https://github.com/Mathetic-PBC/engelbart-canvas)'s
library.

- **Copying.** While the app is running and the pendant is near the Mac,
  what the pendant has stored is copied off it every 15 minutes. The pendant
  is told what arrived and frees the space. Nothing is copied twice.
- **Files.** Each recording is two files in a folder for its day: the audio,
  as the pendant encoded it, in an Ogg Opus file (`.opus`, about 14 MB an
  hour), and a short markdown note with when it started, how long it is and
  a link to the audio.
- **Omi's cloud.** What the Omi app on a phone already took off the pendant
  is in Omi's cloud. With a developer key, each of those conversations is
  copied into the same folder as a markdown note: title, summary, action
  items and the transcript with speakers. The cloud is checked when the Mac
  starts or wakes and every half hour.
- **Engelbart.** If Engelbart is on the Mac, setup asks whether to add the
  folder to its library. It is added once, as a folder, by reference:
  Engelbart lists what is in it live, so every later recording is in reach
  from the `@` menu and nothing is copied into Engelbart.

A menu bar app, like [focus-guard](https://github.com/Mathetic-PBC/focus-guard).

## Install

Needs macOS 14 or later, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

    make install

This builds the app, copies it to `/Applications/OmiImport.app` and opens
it. A waveform appears in the menu bar and the setup window opens.

## Set up

1. **Choose a folder.** **Choose…** picks one, **New Folder…** makes one,
   called `Omi` unless you rename it. Both start in `~/personal` when there
   is one, else in the home folder.
2. **Engelbart.** When Engelbart is installed, the app asks whether to add
   the folder to its library. Engelbart keeps its library in a database that
   only one program may have open, so the folder is added while Engelbart is
   closed: at once if it is, otherwise the next time it quits, or straight
   away with **Quit Engelbart and Add**, which opens it again afterwards.
3. **The pendant.** Quit the Omi app on your phone (the pendant connects to
   one device at a time) and have the pendant on near the Mac. macOS asks
   once for Bluetooth access. The first Omi found is remembered, and from
   then on only that one is used. **Forget** lets another be found.
4. **Omi's cloud.** Make a key at [app.omi.me/developers](https://app.omi.me/developers)
   with the `conversations:read` scope, paste it in and click **Connect**.
   The key is kept in the login keychain. The first check walks the whole
   history; Omi allows 25 transcript requests an hour, so a long history
   comes in over a few hours.
5. **Open at login,** so copying happens without thinking about it.

## How it works

**Copying.** Every 15 minutes, and when **Import Now** is chosen, the app
connects to the pendant, asks what it has stored, and reads it a window at a
time. Each window is written to a journal in the import folder and synced to
disk before the pendant is told it may free it, so quitting the app or
losing the connection at any point loses nothing that had arrived. Then it
disconnects. [docs/protocol.md](docs/protocol.md) has the protocol, where
each part was read from, and why the app doesn't stay connected.

**Recordings.** The pendant stores one unbroken run of audio with a time on
every 444 bytes, and its microphone sleeps through silence. A recording ends
where the times jump by more than a minute, which is the official app's
rule. A recording is written once it has been quiet for a minute.

    Omi/
      2026-11-23/
        2026-11-23 14-05-12.opus    the audio, as the pendant encoded it
        2026-11-23 14-05-12.md      when, how long, a link to the audio
      .omi-import/                  the journal and the list of what was imported

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

**The clock.** The pendant has no clock of its own and this Mac is the only
thing that sets it. After the pendant restarts away from the Mac its times
run early by however long it was off. The app measures that on connecting,
sets the clock, and corrects the times of what was recorded in between. A
recording whose time was corrected, or couldn't be, says so in its note.

**Engelbart.** Engelbart's library is a table with one row per item, in a
PGlite database at `~/.engelbart/library.pglite`. The app adds one row, of
type `folder`, pointing at the import folder, using the copy of PGlite
inside Engelbart.app. It checks first whether any process has the database
open, and refuses if one does. Engelbart doesn't list audio files, which
is what the markdown note beside each recording is for. Engelbart lists
folders only inside the home folder; setup says so if the chosen folder is
elsewhere.

## Limits

- Written from the firmware's source and tested against a simulated pendant.
  It has not yet copied from a real one.
- Firmware 3.0.20 or later. On firmware before 3.0.24 the pendant frees
  audio as it sends it, so a connection that drops mid-copy loses the couple
  of seconds that were in the air.
- The pendant connects to one device at a time and keeps one position in its
  storage. With the Omi app open on a phone, this Mac can't reach the
  pendant, and what the Omi app copies never comes here.
- Audio from the pendant comes with no transcript and no speaker names.
  Conversations from Omi's cloud come with a transcript and no audio.
- The cloud side was tested against a stand-in server written from the
  API's documentation and the backend's source, not against Omi's own.

## Develop

    make test     # the Core package's tests
    make debug    # a debug build, with its own bundle identifier

A debug build refuses to run without `OMI_IMPORT_HOME`, a folder of its own
for settings, so it never touches the installed app's. With
`OMI_IMPORT_HEADLESS=1 OMI_IMPORT_SNAPSHOT=/path/to.png` it draws the
settings window into a PNG without showing anything on screen and quits.

## License

MIT
