# Windows sender: missing cursor (#60)

Handoff for whoever picks this up on the Windows PC. Written 2026-09-14 from the Mac,
where none of this can be compiled or run.

Issue: https://github.com/StephenLovino/BetterCast/issues/60
Reply posted: https://github.com/StephenLovino/BetterCast/issues/60#issuecomment-5659562422
(promises a test build "on the current 1.0.1 line", so post the nightly link there once
this branch builds with the fix)

## Branch

Work here, on `fix/windows-sender-latency-topology` (it contains the `windows-1.0.1` tag).

Do NOT use `fix/windows-cursor`. It was branched off `main`, whose Windows source is older
(VERSION 1.0.0). It compiles in CI, but it conflicts with this branch, and its build would
take a 1.0.1 user backwards. Keep it only as a source for the code below, then delete it.

## Symptom

The cursor never appears on the receiver, except while a window is being dragged.

## Root cause

DXGI Desktop Duplication returns the desktop without the hardware cursor, which Windows
draws in an overlay plane. During a drag Windows switches to a software cursor, so it lands
in the captured image, which is why dragging is the one case that works.

The pointer is delivered alongside each frame, and the sender never reads it:

- `frameInfo.PointerPosition` is only valid when `frameInfo.LastMouseUpdateTime != 0`.
  Read it unconditionally and the cursor parks in the top-left corner.
- `GetFramePointerShape()` only returns data when the shape changed
  (`PointerShapeBufferSize > 0`), and must be called before `ReleaseFrame()`.
  Both position and shape have to be cached between frames.

The GDI fallback has the same gap: `BitBlt ... SRCCOPY` leaves the cursor out.

## Code to reuse

`compositePointer()` and the cached pointer fields from commit `782268d`:

    git show 782268d -- Sources/BetterCastReceiverDesktop/sender/

It handles all three shape types with bounds checks and clipping:

- COLOR: straight alpha blend
- MASKED_COLOR: alpha is a flag, 0 replaces the pixel, 0xFF XORs it
- MONOCHROME: 1bpp, AND mask stacked above XOR mask, so the reported height is double

Copy the function across. Do not cherry-pick the commit; it conflicts.

## The trap on this branch

`captureFrameDxgi()` drops pointer-only frames:

    // LastPresentTime == 0 means only the pointer moved ...
    if (frameInfo.LastPresentTime.QuadPart == 0) { release; continue; }

Those are exactly the frames where the cursor moves. Adding `compositePointer()` without
changing this compiles, passes CI, and still shows no cursor while hovering.

## Changes in captureFrameDxgi()

1. Read pointer position and shape on every acquired frame, before `ReleaseFrame()`,
   pointer-only frames included.
2. Stop discarding pointer-only frames. Mark the frame pending and reuse the newest staging
   texture, `m_stagingTex[m_stagingIndex]`. No `CopyResource`, the desktop did not change.
3. Keep the staging texture clean, since pointer-only frames map it again. Give the staging
   textures `D3D11_CPU_ACCESS_READ | D3D11_CPU_ACCESS_WRITE`, map with
   `D3D11_MAP_READ_WRITE`, save the pixels under the cursor rectangle, composite, call
   `convertAndEmit()`, restore the saved pixels, then `Unmap()`.
4. Let pointer-only updates go through the existing pacing (`m_minFrameIntervalNs`), so fast
   mouse movement does not spike bitrate. The 1-second keep-alive re-emits `m_nv12`, which
   already carries the last cursor position, so it needs no change.
5. GDI fallback, in `captureFrameGdi()` after `BitBlt`: `GetCursorInfo` then `DrawIconEx`.
   `ptScreenPos` is in virtual-desktop coordinates, so subtract the display's origin
   (`EnumDisplaySettings`, `dmPosition`). Link `user32.lib`.

## Optional CI change

This branch already installs NSIS. On the portable upload step, consider:

    if: always() && hashFiles('artifact/**') != ''

so a failing installer step no longer withholds a portable build that packaged fine.

## Testing

1. Connect a receiver and move the mouse without dragging anything. This is the broken case.
2. Hover over text to get the I-beam, which exercises the MONOCHROME path.
3. Change cursors (resize arrows, hand over a link) to confirm the shape cache updates.

If it is wrong, the symptom points at the cause:

| Symptom | Likely cause |
|---|---|
| Cursor stuck in the top-left | position read without the `LastMouseUpdateTime` check |
| Cursor flickers, shows only when the shape changes | shape not cached between frames |
| Cursor only moves when the screen redraws | pointer-only frames still being dropped (step 2) |
| Trails or smears behind the cursor | staging texture not restored before reuse (step 3) |
| Arrow fine, I-beam wrong (solid, inverted, half height) | MONOCHROME mask maths |

The #60 reporter (YourCFP, Intel UHD 620, libx264, MttVDD at 2732x2048) offered to test.
