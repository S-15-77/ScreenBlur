# ScreenBlur

macOS privacy-blur app: blurs the screen on idle, as the MacBook lid closes, and on the side the user turns their head away from (AirPods head tracking). Swift, AppKit + SwiftUI, no dependencies. Repo: https://github.com/S-15-77/ScreenBlur

## Build & run

```sh
./build.sh                          # swiftc → ScreenBlur.app, ad-hoc signed
pkill ScreenBlur; open ScreenBlur.app
```

- Only Command Line Tools are installed, not Xcode. There is no `.xcodeproj`, `xcodebuild` or SwiftPM, so don't add them.
- `build.sh` passes `-module-cache-path` into `$TMPDIR` because the default cache path is blocked in the sandbox. The `xcrun_db ... Operation not permitted` lines are harmless noise.
- Info.plist is generated inside `build.sh`. New permission strings (such as `NSMotionUsageDescription`) go there.
- Smoke test (checks only that the app launches without crashing): run the binary in the background for a few seconds and confirm it's still alive.

## Layout

Everything is in `main.swift`. Keep it a single file unless it gets much larger.

- `App`: the app delegate that owns all state and every trigger.
  - Idle: a 0.25 s `Timer` → `tick()` → `show()` / `hide()`. These fade full-screen overlays on all screens.
  - Lid: `LidSensor` → `lidAngleChanged` sets `lidSpring.target` → `frame(_:)` → `applyLid`.
  - Head: `CMHeadphoneMotionManager` → `headMoved` sets `headSpring.target` (signed: >0 blurs the right side) → `frame(_:)` → `applyHead`.
  - `frame(_:)` is one `CADisplayLink` callback on the built-in screen, in `.common` mode, that steps both springs.
  - `makeWindow(on:)` builds every overlay: a borderless, click-through, non-activating panel bound to its screen at `.screenSaver` level with a container view whose `subviews[0]` is the `NSVisualEffectView`.
- `Spring`: critically damped spring used for all sensor-driven motion.
- `Live`: an `ObservableObject` holding readout strings for the UI.
- `SettingsView`: the SwiftUI settings window.
- `registerHotKey()`: global ⌃⌥⌘B → Blur Now via Carbon `RegisterEventHotKey` (no Accessibility permission).
- Launch at login: `SMAppService.mainApp`, toggled in `SettingsView`. Its state comes from the system, not UserDefaults.
- `icon.swift`: a separate build-time tool that `build.sh` compiles and runs to write `AppIcon.icns`. It is not part of the app.
- `LidSensor`: reads the IOKit HID lid hinge sensor on a background queue and delivers angles on the main thread.

## Conventions and gotchas

- **Settings:** UserDefaults keys are registered in `applicationDidFinishLaunching` and bound with `@AppStorage` in `SettingsView`. A new setting needs its key and default in both places, with matching values.
- **Blur masks:** blur shape comes from `NSVisualEffectView.maskImage` with `capInsets` (`featherMask`). Layer masks don't work with `.behindWindow` blending. Keep the band a fixed size and move its origin rather than resizing it, because a mask squeezed below its cap-inset size renders wrongly.
- **Lid sensor:** HID `05AC:8104`, usage page `0x20`, usage `0x8A`, feature report 1, angle in bytes 1–2 (little-endian degrees). It is an undocumented interface.
- **Head yaw:** the sign convention (turning left → positive) is assumed. The `headInvert` setting exists in case it is wrong on some device.
- **Head tracking permission:** TCC Motion permission resets whenever the ad-hoc signature changes. Fix with `tccutil reset Motion local.macscreenblur`.
- **Testing limits:** the sandbox can't read the lid sensor or AirPods, see processes, or show the UI. Sensor and visual behaviour must be verified by the user on real hardware, so say so instead of claiming it works.
- **Style:** match the existing code. Keep it plain and compact with short "why" comments, and add no dependencies.
