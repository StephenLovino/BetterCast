# App Review demo video: shot list

For BetterCast Display 1.3 (14), answering the **Guideline 2.1** rejection of 2026-06-23
(submission ID `74bbe5e4-7b23-4031-976e-92444f83e1fb`, reviewed on iPad Air 11-inch M3).

## What the reviewer actually asked for

> We need a demo video that shows a physical Apple device and the designated hardware
> pairing together and interacting during the use of the app.
>
> Film the demo video to show both the designated hardware and the app running on a
> physical Apple device.

Three required elements, verbatim:

1. The current version of the app in use on a **physical Apple device, not a simulator**
2. The **initial pairing process** between the app and the designated hardware
3. The **entire app workflow** with the designated hardware

**This must be filmed with a camera, not screen-recorded.** A ReplayKit capture cannot show
a physical device, and it will draw the same rejection. Apple treats the Mac as the
"designated hardware", so the Mac and the iPhone must both be visible in the same frame.

## Setup before recording

- **Delete the app from the iPhone first.** Onboarding only fires on a true first run, and
  onboarding being force-disabled is what caused the 2.1 rejection. It is the single most
  important beat in the video.
- Mac: clean desktop, default wallpaper. No Terminal, no Finder windows showing DMGs, no
  browser tabs. Open Notes or Keynote as the thing you mirror.
- **No Android device anywhere in frame, and no Android references on either screen.**
  Guideline 2.3.10 was cited for exactly this. Do not let a non-Apple phone appear.
- Nothing copyrighted on the Mac screen. No YouTube, no music.
- Prop the iPhone on a stand beside the Mac so both screens are readable. Film in
  landscape, 1080p is plenty.
- Second camera or a friend holding the phone. One continuous take, no cuts.

## Target length 60 to 90 seconds

| Time | What the camera sees | What you say |
|---|---|---|
| 0:00 | Wide shot: Mac and iPhone side by side, iPhone on home screen | "This is BetterCast Display version 1.3, build 14, running on an iPhone. The Mac beside it is running the free BetterCast Sender app." |
| 0:10 | Tap the BetterCast icon, onboarding appears, page through it | "On first launch the app explains what it does and what it needs." |
| 0:25 | Land on the Connect screen, device list empty | "BetterCast is a receiver. It turns this iPhone into a second display for a Mac." |
| 0:33 | Mac appears in the list. Tilt to show the Sender app on the Mac | "The Mac is on the same Wi-Fi network and appears here automatically over Bonjour. There is no proprietary hardware, any Mac running the free sender works." |
| 0:45 | Tap the Mac, connection establishes, stream appears on the iPhone | "Tapping it pairs the two. The iPhone is now showing the Mac's screen, live." |
| 0:55 | **Drag a window on the Mac.** Both screens in frame | "Moving a window on the Mac updates on the iPhone in real time, which shows this is a genuine live connection." |
| 1:05 | Rotate the iPhone to landscape | "Landscape is supported." |
| 1:12 | Settings tab, then Setup Guide tab | "Settings and an in-app setup guide are built in." |
| 1:20 | Disconnect, back to the device list | "Disconnecting returns to the device list." |

The 0:55 beat matters most. Reviewers look for proof that the two devices are genuinely
interacting rather than showing a canned video, so make the Mac-side action and the iPhone
response unmistakably simultaneous in one unbroken shot.

## Delivery

The reviewer asked for a **link**, not an attachment:

> Provide a link to a demo video in the App Review Information section of App Store Connect,
> then reply to this message.

1. Upload as **unlisted** on YouTube
2. Paste the URL into App Store Connect, App Review Information, Notes
3. Reply to the App Review message saying the video is linked in the notes
4. Attaching the file as well does no harm, but the link is what they asked for

## Also required before resubmission

- Replace screenshots containing Android references or non-iOS device images (2.3.10). The
  review device was an iPad, so check the iPad set under "View All Sizes in Media Manager".
- Move the Mac-required disclosure into the first two lines of the Description.
- Rewrite the App Review notes, which currently just say to install the sender from
  bettercast.online.
