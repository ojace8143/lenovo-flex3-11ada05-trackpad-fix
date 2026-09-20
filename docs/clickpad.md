# IdeaPad Flex 3 11ADA05 — clickpad behavior (ELAN 04F3:3072)

The touchpad is a **clickpad**: the whole surface is one physical button, and
there are **no physical buttons exposed to the kernel** on either input device
(`MSFT0001:00 04F3:3072 Mouse` and the `Touchpad` device both report no
`BTN_LEFT`/`BTN_RIGHT` key bits). All clicks are synthesized by libinput.

## Verified behavior (raw libinput captures, kernel 7.2.5-3-omarchy)

| Gesture | Result | Notes |
|---|---|---|
| Single-finger tap | LEFT click | works |
| **Two-finger tap** | **LEFT click (bug)** | the two contacts lift sequentially; libinput decides the tap button from the fingers present at release → sees one finger |
| Three-finger tap | middle click | generally works |
| Physical press, pad center | LEFT click | button-area |
| **Physical press, bottom-right corner** | **RIGHT click** | reliable — this is the dependable right-click on this machine |
| Two-finger physical click | unreliable | fits the same sequential-lift problem |

The `GESTURE_HOLD_*` events show that multi-touch *tracking* itself works fine
(2 fingers are detected); only tap/click *classification at release* is
lossy. This is likely a firmware issue on the ELAN HID controller; a newer
BIOS could theoretically change it, but you can't downgrade past 2.1's
touchpad fix without Windows, so the config below is the pragmatic answer.

## Recommended configuration (Hyprland / Omarchy)

See `config/hypr/input.lua` for the snippet. Key points:

- `tap_button_map = "lrm"` — 1 finger left, 2 right, 3 middle (when tapping
  cooperates).
- `clickfinger_behavior = false` — keep *button-area* method so a physical
  press on the bottom-right corner is a right-click.
- `tap_to_click = true` — single-finger tap stays a reliable left-click.

## Why the physical "no buttons" matters

Because the kernel sees no `BTN_RIGHT` at all, the only sources of a
right-click are:

1. libinput **button-area** physics (bottom-right corner press), or
2. the **two-finger tap / clickfinger** methods, which are flaky here.

If your unit's two-finger tap reliably right-clicks, great — leave
`clickfinger_behavior = true` instead. If it's inconsistent, use the
bottom-right corner.

## Debugging tools

```sh
libinput list-devices | grep -A20 "04F3"
libinput debug-events --show-keycodes --device /dev/input/eventXX
```

The "Mouse" and "Touchpad" event X numbers can shift between boots — map them
via `/proc/bus/input/devices` or `/sys/class/input/event*/device/name`.

## On Linux Mint (Cinnamon) / GNOME

The same libinput behavior applies — these are just GUI equivalents:

- **Cinnamon**: System Settings → Mouse and Touchpad → enable *Enable
  tap-to-click*; use the click action for the *bottom-right corner* (button
  area) rather than relying on two-finger taps.
- **GNOME**: Settings → Mouse & Touchpad → *Tap to click*, and the click-action
  method (*two-finger* vs *areas in corner*) picker.