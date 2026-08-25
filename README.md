# Rocksmith 2014 on Linux: guitar input that actually works ©

Run one script. Click two things in Steam. Your guitar makes noise in the game.
That's it, that's the repo.

## Why this exists

Okay so Rocksmith 2014 is genuinely one of the coolest things Ubisoft has ever
put out. You plug a real guitar into a computer and it teaches you to play it.
And they've done nothing with it. No Linux build, no port, no patch, nothing.

<img width="500" height="620" alt="out" src="https://github.com/user-attachments/assets/74442f4e-63e7-40bf-9836-0e2563e59c4d" />
<br>

It's just sitting there. 

---
So I had to go balls deep, cause I'd rather fall into coma than switch back to Windows. I got u.

<img width="498" height="278" alt="Ill Do It Myself GIF" src="https://github.com/user-attachments/assets/fe12ab6f-ca10-41b2-a789-a357cb3a0b85" />

---
The game runs fine under Proton, that part's whatever. Your guitar is the
problem. Rocksmith wants ASIO, which is a Windows audio thing that doesn't exist
on Linux, and the normal fix for that (WineASIO) doesn't build anymore on a
bunch of distros. Not "it's tricky." Not "you need a flag." The 32-bit Wine libs
it needs literally aren't packaged. Cast into oblivion. Gone.

<img width="480" height="272" alt="Hold Up Superman GIF" src="https://github.com/user-attachments/assets/1a8ff1f2-f223-4172-a254-22e98a189e0c" />

---

I found this out by watching a linker fail for days in like six
different flavors. Masterclass in bad decision-making and I was the whole
faculty. Anyway PipeASIO fixes it. Talks straight to PipeWire, builds its 32-bit half with
MinGW instead of Wine's toolchain, dodges the whole mess. Works great. Just
annoying enough to set up that you'd quit around step four.


---

So, script.

```
your guitar → PipeWire → PipeASIO → RS_ASIO → Rocksmith
```
## Setup

```sh
git clone https://github.com/UkrainianCitizen/rocksmith-linux-pipeasio-guitar-input-fix
cd rocksmith-linux-pipeasio-guitar-input-fix
./rocksmith-pipeasio-setup.sh
```

Two things it can't do for you, because they live in Steam's binary config and
get wiped if Steam's running when you poke it:

1. **Compatibility** → force **GE-Proton 11.x**. Not Valve's. Read the next bit
   before you fight me on this.
2. **Launch Options** → `PROTON_USE_WOW64=1 %command%`

Hit Play, run the calibration, go be a rockstar alone in your room.

Proton updates and everything dies:

```sh
./rocksmith-pipeasio-setup.sh --reapply
```

> Heads up, `--reapply` is tested, the full run isn't. It's stitched from steps I
> did by hand one at a time and has never gone start to finish on a clean box.
> Read it first. It's short. I'm not your dad.

---

## Three things that will absolutely get you

**Valve's Proton just ignores the flag.** You set `PROTON_USE_WOW64=1`, Valve's
`11.0-100` looks at it, and does nothing. No error. No warning. Nothing in the
log going "hey, skipping that." It just doesn't, and then PipeASIO faceplants
with "the 64-bit unixlib is unavailable" and you're forty minutes deep debugging
a driver that was fine the whole time. GE-Proton actually honors it. Use GE. This
one cost me the most and I'm still kind of mad.

**Every Proton update nukes the driver.** Files have to sit *inside* the Proton
build because Proton won't pass through a `WINEDLLPATH` you set yourself. There's
[a PR](https://github.com/ValveSoftware/Proton/pull/9420) that fixes it. It's
been open long enough to grow a beard. So every update: `--reapply`. Yeah.
Again. It is what it is.

**The Real Tone Cable is mono.** One channel. Set `inputs = 2` and you get this
beautiful uninterrupted buzz and zero detected notes, and you'll sit there
plucking at a dead game like a goober wondering what you broke. Skill issue.
Mine. Took me way too long.

---

## When it breaks

<img width="480" height="278" alt="Iron Man Kill GIF" src="https://github.com/user-attachments/assets/4d181b3a-d22e-4836-a3ac-33e306e62377" />

| Symptom | What's actually going on | Fix |
|---|---|---|
| `the 64-bit unixlib is unavailable` | WoW64's off | Add `PROTON_LOG=1`, launch, `grep -m1 "Options:" ~/steam-221680.log`. No `wow64` in there → your Proton's ignoring you, switch to GE. It's there → `--reapply` |
| Dies in a second, no window, no log | Busted launch options | Check the trailing `%` on `%command%`. Steam fails dead silent on a broken string. Fantastic. Tremendous |
| Constant buzz, plucking does nothing | Wrong `inputs`, or it grabbed your webcam mic | `pipeasio-settings`, fix both |
| Crackling, dropouts | Buffer's too small | `buffer_size` 256 → 512 in `~/.config/pipeasio/config.ini`. Re-reads live so you can tune it mid-song. `sample_rate` has to be 48000, no exceptions |
| Tone won't switch mid-song, Riff Repeater's possessed | Game's just like that | Nothing. Standard operating procedure. Does it on Windows too. It's a decade old, let it live |

## What the script does


Builds PipeASIO with 32-bit WoW64 support, installs it, drops it where Proton can
actually see it, registers it in the prefix, grabs RS_ASIO, writes the configs,
and works out which thing is your guitar adapter and whether it's mono. Finds
your distro, your Steam library, and wherever you stashed the game.

You don't edit anything. No paths to fill in. If it can't find something it says
what and stops, instead of barreling ahead and handing you a half-wired audio
stack.

<img width="209" height="241" alt="1000011101" src="https://github.com/user-attachments/assets/c2e0a63d-b812-47ee-9b9c-15f9241092f1" />

---

<sub>Confirmed on Nobara 43, GE-Proton 11, PipeWire 1.6.8, PipeASIO 1.5.0, RS_ASIO 0.7.5, Real Tone Cable. Written to work anywhere, tested on that. Ran it somewhere else? Open an issue and tell me if it worked or exploded, both help.</sub>

<sub>None of this is my discovery, I just glued it together and wrote it down. nizo's guide is the only reason this game runs on Linux at all, and he's the one who pointed me at PipeASIO when WineASIO dead-ended. rein figured out the Proton ≥ 11 thing, that RS_ASIO has to be 0.7.5, and casually mentioned pipeasio-settings exists, which I'd completely missed. M0n7y5 makes PipeASIO, mdias makes RS_ASIO. Built with AI, tested on my own machine. CC BY-SA 4.0, same as nizo's, since it stands on his work.</sub>

<sub>Smell ya later.</sub>
