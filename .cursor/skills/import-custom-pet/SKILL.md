---
name: import-custom-pet
description: Imports, uploads, installs, resets, or troubleshoots custom Codex Pet packages on this project's ESP device through the local USB bridge. Use when the user mentions importing a pet, uploading a spritesheet, changing the ESP pet, xijingping pet, pet.json, spritesheet.webp, or the 127.0.0.1:8765 pet controls.
---

# Import Custom Pet

Use only this project's `aiclock-usb` service and USB control page. Never launch,
install, or route pet operations through AIClockBridge.

## Supported input

A pet directory must contain exactly one `pet.json` and its referenced
`spritesheet.webp` or PNG.

- v1: 1536x1872, 8 columns x 9 rows, 192x208 per cell.
- v2: `spriteVersionNumber: 2`, 1536x2288, 8 columns x 11 rows. ESP imports the
  first nine rows.
- The installed ESP payload is `AIPET1`: 57 frames, 120x120 RGB332, 820,928
  bytes, with CRC32.

Treat the source directory as read-only. Reject a `spritesheetPath` that escapes
the pet directory. Do not silently resize or repair a malformed package.

If the user only has character art rather than a complete package, say that a
Codex Pet package must be created first. Use `hatch-pet` when it is available
and the user also asks to create or repair the pet.

## Workflow

1. Resolve the pet directory from the user's path or the project context. Common
   installed packages live under `~/.codex/pets/<id>/`.
2. Read `pet.json`; verify `id`, `spritesheetPath`, referenced file existence,
   dimensions, and v1/v2 compatibility.
3. Inspect the local bridge before changing anything:

   ```bash
   curl -sS http://127.0.0.1:8765/api/status
   ```

   Require `usb.connected: true` and `usb.protocol >= 3`. Report the detected
   firmware, port, and current `custom_pet` value.
4. Visually inspect an existing QA contact sheet when provided. If no QA exists,
   inspect the spritesheet or representative frames for clipping, opaque
   backgrounds, inconsistent identity, and unusable state rows.
5. Choose one import path below. Do not run both.
6. Verify the final bridge response contains `usb.connected: true` and
   `usb.custom_pet: true`.

## Import paths

### User-driven control page

Use this when the user asks where to upload, wants to operate the UI, or the
package is v2:

1. Open `http://127.0.0.1:8765/`.
2. In **Codex 九状态宠物**, choose the directory containing `pet.json`.
3. Click upload and keep USB connected until the page reports installation.
4. Poll `/api/status` until `pet_upload.active` is false; fail if
   `pet_upload.error` is non-null.

The browser performs conversion locally. Do not upload pet files to an external
service and do not modify Codex desktop pet settings.

### Agent-driven USB CLI

Use this when the user supplies an accessible v1 package and asks the agent to
complete the installation. The background bridge owns the serial port, so stop
it temporarily and always restore it afterward.

Run the provided script from any directory:

```bash
.cursor/skills/import-custom-pet/scripts/install-pet.sh ~/.codex/pets/<id>
```

The script builds the release CLI, stops only `local.aiclock-usb`, runs
`aiclock-usb pet-install`, and restores the 8765 LaunchAgent even after failure.
Request the required local process/serial approval when the execution sandbox
requires it.

The CLI converter currently accepts v1 1536x1872 packages. For v2, use the
control page unless the converter has been updated and verified.

## Reset

When the user explicitly asks to restore the firmware pet:

```bash
curl -sS -X POST http://127.0.0.1:8765/api/pet/reset
```

Verify `usb.custom_pet: false`. Do not reset a custom pet merely to diagnose an
upload problem because the device cannot retain two full custom payloads.

## Troubleshooting

- Control page unavailable: check `launchctl print gui/$(id -u)/local.aiclock-usb`
  and whether port 8765 is listening. Reinstall only the `aiclock-usb`
  LaunchAgent when necessary.
- USB disconnected: inspect `/dev/cu.usbserial*`; do not guess another serial
  device if more than one candidate exists.
- Protocol below 3: report that the ESP firmware must be updated before custom
  pet upload.
- Upload interrupted or CRC rejected: keep the built-in fallback, restore the
  bridge, and report the exact failed stage. Retry only after the connection is
  stable.
- Serial busy: check for another `aiclock-usb` process. Do not start
  AIClockBridge as a workaround.

## Completion report

Lead with whether installation succeeded. Include:

- pet id/display name and source directory;
- USB port, firmware, and protocol;
- upload/CRC confirmation;
- final `custom_pet` value;
- the control-page link;
- any validation or build commands that failed.

Do not claim the device knows the pet's name: its status reports only whether a
custom pet is installed.
