# Primfold for iOS

Native SwiftUI client for iPad and iPhone, currently targeting iOS 27 or later. The app now includes an initial Second Life login and simulator connection, nearby chat, short walking steps, and a RealityKit view of streamed object bounds. The desktop viewer and its build remain separate.

## Connected version

1. Build and run the shared `Primfold` scheme. Open **World**.
2. Enter your account username (one name, `first.last`, or `First Last`) and password. Do not use a display name or email address. One-name accounts use the `Resident` last name automatically.
3. Choose Second Life or Second Life Beta, and Last location or Home. Supply an authentication code if your account requires it.
4. Read the linked Terms of Service, check the agreement, and select **Sign In**. The app reports server login errors and waits for the simulator to confirm entry before showing Connected.
5. Use the short-step and turn buttons, open **Nearby Chat**, or select **Sign Out**. Entering the background signs out because iOS suspends the simulator connection.

This is an early connected client, not a complete mobile port. The 3D view draws untextured bounding boxes at the positions, scales, rotations, and parent transforms sent by the simulator. Avatar bounds are teal. It shows up to 2,000 object bounds within the current region; it does not draw terrain, mesh assets, textures, avatar appearance, or animations. Inventory, object editing, teleporting, region crossings, and voice are not implemented. Sign out before moving between regions. Signing in can disconnect another viewer using the same account.

Login uses HTTPS XML-RPC. Passwords and MFA codes are never saved, and login responses are not logged. Only a random installation identifier is persisted. Simulator traffic uses LLUDP, with reliable packet acknowledgements, duplicate suppression, retries, ping responses, and connection timeouts. Layouts and message numbers follow `../scripts/messages/message_template.msg`; login and object decoding also follow the desktop viewer code.

## Automated checks

Run **Product → Test** (⌘U) with the Primfold scheme. `PrimfoldTests` uses Swift Testing. Relative source symlinks compile the production login, packet, and session files into the standalone test bundle so protocol checks do not require launching the app or signing into an account.

Checks cover XML-RPC parsing, account-name handling, malformed and zerocoded packets, byte order, object updates, signed circuit codes, cancellation, and a loopback UDP simulator fixture. The fixture exercises a dropped circuit packet, region confirmation, duplicate chat, sending chat, movement controls, and logout. These checks do not authenticate against Second Life. A successful account login, actual appearance in the region, and interoperability with a live simulator still require device verification.

Verified November 24, 2026: Xcode build succeeded and all 33 checks passed. The login UI was inspected on iPhone Duo and iPad (A16) simulators. On iPad, dummy field entry, agreement gating, and World/Creator navigation passed. No credentials were submitted to a live grid. A RealityKit snippet also verified linked bounds, camera coordinate conversion, and removal of stale entities.

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
