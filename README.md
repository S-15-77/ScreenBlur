# ScreenBlur

**Privacy blur for your Mac that reacts to you.** Blurs the screen when you walk away, as you close the lid, and on whichever side you turn your head away from, with smooth, spring-animated transitions in the style of macOS.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Swift](https://img.shields.io/badge/swift-5.9%2B-orange)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

---

## Features

| Trigger | What happens |
|---|---|
| **Idle** | After a set time with no keyboard or mouse input, every display fades into a frosted blur. Any input fades it back out. |
| **Lid** | As you close a MacBook lid, the built-in screen blurs gradually, bottom first. When you open it, the blur clears from the top down. |
| **AirPods head tracking** | Turn your head left and the right side blurs. Turn right and the left side blurs. The blur follows how far you turn and has a soft, feathered edge. |
| **Blur Now** | Blur all screens on demand, from any app with **⌃⌥⌘B**. |

- Native Swift, AppKit and SwiftUI. One source file, no dependencies.
- Uses the system blur (`NSVisualEffectView`), so it matches the look of macOS.
- Animations use critically damped springs and run in sync with the display refresh.
- Clicks pass through the blur, so it never blocks your apps.

## Requirements

- macOS 14 Sonoma or later
- Xcode Command Line Tools (`xcode-select --install`). The full Xcode app is not required.
- **For lid blur:** a MacBook with a lid angle sensor (most recent Apple silicon MacBooks)
- **For head tracking:** AirPods Pro, AirPods Max, or AirPods (3rd generation or later)

## Installation

Build from source:

```sh
git clone https://github.com/S-15-77/ScreenBlur.git
cd ScreenBlur
./build.sh
open ScreenBlur.app
```

`build.sh` compiles `main.swift`, packages `ScreenBlur.app`, and ad-hoc signs it. To keep it around, move the app into `/Applications`.

## Usage

When you launch ScreenBlur, it opens its settings window and adds an icon to the Dock and the menu bar. If you close the window, the app keeps running in the background. Click the Dock icon to reopen the window. Quit with **⌘Q**.

### Settings

All settings save instantly and persist across launches.

| Section | Setting | Default |
|---|---|---|
| General | Launch at login | Off |
| Idle | Blur when idle | On |
| | Idle delay | 60 s (5 s – 10 min) |
| Lid | Blur as the lid closes | On |
| | Blur starts at | 95° |
| | Fully blurred at | 50° |
| AirPods | Blur the side I look away from | On |
| | Trigger angle | 25° |
| | Swap sides | Off |
| | Recenter | Sets "looking at the screen" to your current head direction |

The window also shows the live lid angle and head-turn angle, which help with tuning and troubleshooting.

Settings live in the `local.macscreenblur` defaults domain, so you can also script them:

```sh
defaults write local.macscreenblur idleSeconds -float 30
```

## Permissions

| Permission | Why | Where to grant |
|---|---|---|
| Motion & Fitness | To read AirPods head orientation | System Settings → Privacy & Security → Motion & Fitness |

The idle and lid features need no permissions.

> Each rebuild produces a new ad-hoc signature, so macOS may ask for permission again. If head tracking stops working after a rebuild, run:
> ```sh
> tccutil reset Motion local.macscreenblur
> ```

## How it works

- **Idle detection:** polls `CGEventSource.secondsSinceLastEventType` four times a second. This needs no Accessibility permission.
- **Lid angle:** reads the MacBook's hinge sensor (Apple HID device `05AC:8104`, usage page `0x20`, usage `0x8A`) through IOKit on a background queue. The angle drives a spring, which sets both the blur opacity and the position of a screen-tall gradient mask.
- **Lid wake reveal:** when the display sleeps, the blur is set to full. When it wakes, a slower spring plays the top-to-bottom reveal.
- **Head tracking:** `CMHeadphoneMotionManager` provides yaw relative to the direction you faced when tracking started. The yaw is mapped to a signed blur amount with a dead zone, smoothed by a spring, and drawn as a band that slides in from the screen edge with a feathered inner edge.
- **Overlays:** borderless, click-through windows at screen-saver level that appear on all Spaces and over full-screen apps.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Nothing seems to happen | This is expected until a trigger fires. Use **Blur Now** to test the blur. |
| Lid angle shows "Sensor unavailable" | Your Mac has no readable lid angle sensor, so lid blur is not available. |
| Head turn shows "Waiting for AirPods" | Put both AirPods in your ears and make sure they are the current sound output. |
| Head turn shows "Permission denied" | Enable ScreenBlur under Motion & Fitness (see [Permissions](#permissions)). |
| Head turn shows "Unsupported" | Your AirPods model does not report head motion. |
| The wrong side blurs | Turn on **Swap sides**. |
| Blur triggers while you're looking at the screen | Look at the screen and press **Recenter**. |
| Launch at login won't stay on | Allow ScreenBlur in System Settings → General → Login Items. The login item points at the app's current location, so move it to `/Applications` first. |
| ⌃⌥⌘B does nothing | Another app already owns that shortcut. |
| Menu bar icon is missing | The notch may be hiding it. Use the Dock icon instead. |

## Project structure

```
ScreenBlur/
├── main.swift   # entire app: triggers, sensors, overlays, settings UI
├── icon.swift   # draws the app icon at build time
├── build.sh     # compile, package and sign ScreenBlur.app
├── CLAUDE.md    # notes for AI coding assistants
└── README.md
```

## Roadmap

- [x] Launch at login
- [x] Global hotkey for Blur Now
- [x] Custom app icon
- [ ] Signed and notarized release builds

## Contributing

Issues and pull requests are welcome. Please:

1. Keep the app dependency-free and in plain Swift.
2. Build with `./build.sh` and test on real hardware. The sensors can't be simulated.
3. Describe what you tested (Mac model, macOS version, AirPods model) in your PR.

## License

No license has been chosen yet. Add a `LICENSE` file (for example, MIT) before publishing.

## Disclaimer

The lid angle sensor is an undocumented Apple interface and may change or stop working in future macOS releases. ScreenBlur is not affiliated with or endorsed by Apple.
