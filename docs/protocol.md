# The pendant's storage protocol, as this app uses it

Read from source on 2026-11-23, not from documentation:

- [BasedHardware/omi](https://github.com/BasedHardware/omi) `main` at `a75daeba`,
  and the tags `Omi_CV1_v3.0.24` and `Omi_CV1_v3.0.21`. Firmware paths below
  are under `omi/firmware/omi/src/`.
- The official app's `app/lib/services/wals/ring_storage_sync.dart`,
  `ring_protocol.dart` and `PENDANT_RING_CUSTODY.md`.
- [j2h4u/omi-collector](https://github.com/j2h4u/omi-collector) v1.1.16, a
  Linux service that does the same job for firmware 3.0.21.

None of it has been run against a pendant yet. The tests drive the code with
a simulated pendant written from the same source (`Core/Tests/…/FakePendant.swift`).

## Two firmwares

Which one a pendant runs decides most of what follows.

| | 3.0.20 – 3.0.23 | 3.0.24 and later |
|---|---|---|
| Released | 3.0.21 on 2026-08-05, to everyone | 2026-11-09; at the time of writing its rollout was 0%, one account |
| INFO reply | 31 bytes | 41 bytes, with capabilities and a ring id |
| A record is freed | by the pendant, as it sends it | only when the app says so (`ADVANCE_ID`) |
| Connected, nobody listening to live audio | audio is **thrown away** | audio is stored |
| Connected, live audio subscribed | sent live, not stored | sent live, not stored |
| Clock never set | nothing is stored at all | stored, stamped with seconds since start-up |

The app tells them apart by the INFO reply, not the version string: a build
from `main` also calls itself 3.0.24.

## Services

Every `19B1…` UUID ends `-E8F2-537E-4F6C-D104768A1214`.

| Service | Characteristic | Use |
|---|---|---|
| Audio `19B10000` | `19B10001` notify | live audio: `[index u16 LE][fragment u8][Opus bytes]` |
| Storage `30295780-4301-EABD-2904-2849ADFEAE43` | `30295781-…` write with response, notify | commands in, every reply out |
| Time `19B10030` | `19B10031` write | u32 LE seconds since 1970, exactly 4 bytes |
| | `19B10032` read | the same; 0 when never set |
| Device information `180A` | `2A26` read | firmware version |

The pendant advertises the audio service's UUID, which is what the app scans
for. It accepts one connection at a time (`CONFIG_BT_MAX_CONN=1`), and
nothing needs pairing.

## The ring

One ring of 444-byte records on the SD card, numbered from 0. `read_seq` is
the oldest record not yet freed, `write_seq` the next to be written. When
the ring is full the oldest records are overwritten and `dropped` counts
them.

A record is `[time u32 BE][440 bytes]`. The 440 bytes are `[length u8][Opus
frame]` entries, zero-padded. A zero length byte is padding. A length that
would run to the end of the 440 bytes is 3.0.21's leftover (the frame went
into the next record) and what follows it is stale, so reading stops there
(`PendantRecord.frames`, the same rule as the app's `parseAudioPayload`).

The audio is Opus, 16 kHz mono, 20 ms frames, about 32 kbit/s, CELT only
(`config.h`: `CODEC_ID 21`). About five frames fit a record.

The time is when the record was written, so about the end of its audio, in
whole seconds. From 3.0.24, a value with the top bit set counts seconds since
the pendant started, because its clock wasn't set.

There are no files and no markers between recordings. The microphone sleeps
through silence, so a pause shows up as a jump in the times. Like the
official app, this one starts a new recording where the times jump forward
by more than a minute or go backwards.

## Commands

Written to `30295781`. Multi-byte fields are big-endian.

| | Bytes | Reply |
|---|---|---|
| INFO | `10` | INFO |
| READ | `11` start u64, count u32 | READ_BEGIN, DATA…, DONE |
| ADVANCE | `12` seq u64 | ACK |
| ADVANCE_ID (3.0.24+) | `15` ring u64, seq u64 | ACK |
| STOP | `03` | ACK |

Replies, as notifications on the same characteristic (which must be
subscribed first, or the pendant discards them):

| | Bytes |
|---|---|
| ACK | `01` status |
| INFO | `02` read u64, write u64, capacity u32, dropped u64, record size u16, then on 3.0.24+ capabilities u8, version u8, ring id u64 |
| DATA | `03` then record bytes; notifications don't line up with records |
| DONE | `04` status, next seq u64 |
| READ_BEGIN | `05` start u64, count u32 |

Status: 0 fine, 6 unknown command, 9 not ready or busy, 10 sequence out of
range, 11 wrong ring.

## One copy

1. Connect. Subscribe to live audio at once (see below), and to the storage
   characteristic. Read the pendant's clock.
2. INFO. On 3.0.24+, stop listening to live audio: it stores while connected.
3. If the pendant's clock is 2 s or more from the Mac's, or unset, write the
   Mac's time. If it was more than 5 s off, note the difference and the
   ring's `write_seq`: records before that number carry the old clock.
4. On 3.0.24+, if records were saved by an earlier run that the pendant was
   never told about, send ADVANCE_ID for them first.
5. READ up to 2700 records from `read_seq` (the official app's window, about
   1.2 MB). Cut the DATA bytes into records.
6. Append the records to a journal in the import folder and sync it to disk.
   Only then send ADVANCE_ID (or ADVANCE on older firmware).
7. INFO again; repeat from 4 until `read_seq == write_seq`.
8. Write the recordings that are over (below), disconnect, and come back in
   15 minutes.

If DONE's count disagrees with what arrived, a notification was lost. On
3.0.24+ the window is read again, since the pendant still has it. On older
firmware the pendant has already freed it, so what arrived whole is kept.

Timeouts are the official app's: 5 s for a reply, 15 s between DATA
notifications.

## Why the app doesn't stay connected

Staying connected would make new audio arrive sooner. On firmware before
3.0.24 it would also mean the pendant stores nothing for as long as the Mac
holds the connection, and everything depends on live notifications arriving,
which the firmware gives up on after three tries. Short connections keep
the audio on the pendant's own storage for all but the minute or two a copy
takes.

While it is connected, the app listens to live audio and packs the frames
into records of the same shape, stamped with the Mac's clock, in a journal
of their own. When recordings are written, the records of every journal are
put in one line by time, so a conversation that was going on when the Mac
connected comes out as one recording: stored, then live, then stored.

## What can still be lost

- **Firmware before 3.0.24, connection dropped mid-copy.** The pendant frees
  records as it sends them; those in the air when the connection drops are
  gone. Its own issue tracker measured about 21 records, some 2.5 s.
- **Firmware before 3.0.24, the second or two between connecting and the
  live audio subscription taking effect.** Audio in that gap is neither
  stored nor sent.
- **The phone app.** The pendant keeps one position for everyone. What the
  Omi app copies and frees never reaches this Mac.
- **A full ring.** The pendant overwrites its oldest records; INFO's
  `dropped` says how many, and the app logs it.

## The clock

The pendant has no clock of its own (`rtc.c`). It counts up from the last
time it was told the time, and keeps that moment in flash. After a restart it
counts up from the same moment again, so until it is next told the time,
everything is stamped early by however long it was off. Since this app
replaces the phone app, this Mac is the only thing telling it the time.

So on connecting, the app measures the difference before setting the clock,
and when recordings are written it puts the times right
(`ClockCorrection.apply`): within the records that carry the old clock, a
step backwards in the times is where the pendant restarted. Records after
the last restart are off by exactly the measured difference and are
corrected. Records before the first were stamped by a clock this Mac had
set, and are left. Records between two restarts are off by an amount nobody
measured; they are written with a note saying so.

One case goes wrong: the pendant restarts and its first new record lands
later on its restarted clock than its last old one did, so there is no step
back to see. That takes a recording made within minutes of a copy, a
restart, and another recording made sooner after the restart than the first
was after the copy. Then the old recording is corrected too, and ends up
late by the time the pendant was off. The note beside it says a correction
was made.

## Not known yet

- Which firmware the pendant this was written for runs.
- The speed of a copy on a Mac. The app's own notes say about 68 records a
  second on a phone, some eight times faster than audio is recorded. The app
  logs its own figure after each copy.
- Why some pendants' clocks run minutes fast, as omi-collector reports.
- How many records a retail pendant's ring holds. INFO says; the app logs it.
