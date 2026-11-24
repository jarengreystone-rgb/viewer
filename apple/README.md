# Primfold for iOS

Minimal native SwiftUI shell for iPad and iPhone Duo, targeting iOS 17 or later. Grid login, networking, world rendering, and creator tools are deferred. The desktop viewer and its build remain separate.

## Run

Open `Primfold.xcodeproj`, select the shared `Primfold` scheme, and choose an iPad or iPhone Duo simulator. For a physical device, choose your development team in Signing & Capabilities. The initial bundle identifier is `org.primfold.viewer`.

The app uses scene-based SwiftUI navigation that collapses into a stack at compact widths and shows a sidebar beside the detail at expanded widths. Selection belongs to the scene and survives width changes. Text scrolls when space is limited and uses Dynamic Type text styles.

## Build verification — November 24, 2026

Using Xcode 27.2 (27B52), both completed successfully:

- Debug, generic iOS Simulator, SDK 27.2 (universal arm64 and x86_64).
- Debug, generic iOS device, SDK 27.2 (arm64), with code signing disabled.

Physical-device signing, installation, and execution were not verified. Build commands:

```sh
xcodebuild -project Primfold.xcodeproj -scheme Primfold -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Primfold.xcodeproj -scheme Primfold -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The built Info.plist confirms both iPhone/iPad device families, a generated launch screen, scene support, and all four orientations. There is no full-screen opt-out.

## Runtime verification — iOS 27.2 simulators

- iPad Pro 11-inch (M5): launched at 834×1210 points with sidebar and detail visible. Navigated World → Creator Tools. Resized the running window to 375×535 points: sidebar collapsed into a navigation stack, Creator Tools remained selected, and the content stayed readable without overlap or clipping.
- iPhone Duo: launched at 466×678 points with compact navigation. Verified World → Back → workspace list → Creator Tools and clean text wrapping.
- Both simulator sessions were closed after inspection. Duo unfolding itself was not exercised; live width adaptation was verified using the iPad window.

## Repeatable layout smoke check

1. Launch at compact width. Open the workspace menu and navigate between World and Creator Tools.
2. Expand the window or unfold iPhone Duo. Confirm the sidebar and selected detail are visible together.
3. Select Creator Tools, then narrow and expand again. Confirm the selection remains.
4. Rotate and resize the window; scroll the content at short heights and large text sizes. Check for clipped text and overlapping controls.
