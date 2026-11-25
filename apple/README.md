# Primfold for iOS

Native SwiftUI client for iPad and iPhone, currently targeting iOS 27 or later. The app now includes an initial Second Life login and simulator connection, nearby chat, short walking steps, optional Keychain account storage, and an initial RealityKit geometry preview. The desktop viewer and its build remain separate.

## Connected version

1. Build and run the shared `Primfold` scheme. Open **World**.
2. Enter your account username (one name, `first.last`, or `First Last`) and password. Do not use a display name or email address. One-name accounts use the `Resident` last name automatically.
3. Choose Second Life or Second Life Beta, and Last location or Home. Supply an authentication code if your account requires it.
4. Optionally enable **Remember account on this device** to save this grid’s username and password in Keychain. **Forget Saved Account**, or turning Remember off, removes the saved entry. Authentication codes are never saved.
5. Read the linked Terms of Service, check the agreement, and select **Sign In**. The app reports server login errors and waits for the simulator to confirm entry before showing Connected.
6. Use the short-step and turn buttons, open **Nearby Chat**, or select **Sign Out**. Entering the background signs out because iOS suspends the simulator connection.

This is an early connected client, not a complete mobile port. The 3D preview draws undeformed, uncut box and cylinder primitives from simulator shape parameters, using their default tint. Unsupported shapes and avatars remain bounding boxes at their simulator positions, scales, rotations, and parent transforms. Avatar bounds are teal. It shows up to 2,000 object bounds within the current region; it does not draw terrain, mesh assets, textures, avatar appearance, or animations. Inventory, object editing, teleporting, region crossings, and voice are not implemented. Sign out before moving between regions. Signing in can disconnect another viewer using the same account.

Login uses HTTPS XML-RPC. Username/password storage is opt-in and uses non-synchronizing Keychain entries with WhenUnlockedThisDeviceOnly protection, separated by grid. Keychain work runs outside the main actor. MFA codes and simulator session credentials are never saved. Login responses are not logged. A random installation identifier is persisted separately in preferences. Simulator traffic uses LLUDP, with reliable packet acknowledgements, duplicate suppression, retries, ping responses, and connection timeouts. Layouts and message numbers follow `../scripts/messages/message_template.msg`; login and object decoding also follow the desktop viewer code.

## Rendering target: desktop visual compatibility

Full client appearance is the target, and is not implemented yet. The mobile decoder now retains the original 23-byte primitive shape parameters, per-face texture entries, sculpt/mesh parameters, and material parameters from full and compressed simulator updates. Texture entry decoding retains face overrides, UUIDs, colors, UV transforms, fullbright/shininess, glow, and legacy material identifiers.

The remaining rendering work is substantial:

1. Negotiate seed capabilities and implement bounded asset fetching/caching for GetMesh/GetMesh2 and GetTexture. Decode JPEG 2000 textures and mesh LODs using the desktop formats, with per-face material assignments.
2. Port the full parametric and sculpt geometry behavior from `indra/llmath/llvolume.cpp` and `indra/llprimitive/llvolumemessage.cpp`, including cuts, hollowing, twist, taper, and UV generation.
3. Implement avatar skeletons, skin weights, body morphs, animation, baked appearance textures, mesh bodies/clothing, and attachments. Relevant references include `indra/llappearance`, `indra/llcharacter`, and `indra/newview/llvoavatar.cpp`.
4. Implement terrain and the legacy/PBR material and environment rendering paths. Validate live scenes against the desktop client with the same account, assets, region, and lighting.

The desktop geometry libraries currently depend on desktop support libraries and its rendering stack; they cannot simply be linked into the SwiftUI target. Geometry/asset decoding needs an iOS-compatible bridge or native implementation, and graphics need a Metal-compatible rendering path. The current RealityKit preview must not be described as desktop visual parity.

## Automated checks

Run **Product → Test** (⌘U) with the Primfold scheme. `PrimfoldTests` uses Swift Testing. Relative source symlinks compile the production login, packet, and session files into the standalone test bundle so protocol checks do not require launching the app or signing into an account.

Checks cover XML-RPC parsing, account-name handling, malformed and zerocoded packets, byte order, object updates, signed circuit codes, cancellation, and a loopback UDP simulator fixture. The fixture exercises a dropped circuit packet, region confirmation, duplicate chat, sending chat, movement controls, and logout. These checks do not authenticate against Second Life. A successful account login, actual appearance in the region, and interoperability with a live simulator still require device verification.

Initial connected-preview verification, November 24, 2026: Xcode build succeeded and all 33 checks passed. The login UI was inspected on iPhone Duo and iPad (A16) simulators. On iPad, dummy field entry, agreement gating, and World/Creator navigation passed. No credentials were submitted to a live grid. A RealityKit snippet also verified linked bounds, camera coordinate conversion, and removal of stale entities.

Saved-account and appearance update verification, November 24, 2026:

- The IDE app/test build and a fresh on-disk Release simulator app/test build passed. The fresh build used Swift 6, complete concurrency checking, and Swift warnings as errors.
- A temporary Mac test harness compiled the production core source and passed 27 Swift Testing functions (40 parameterized cases) without interrupting the active simulator session.
- An app-host snippet verified actual Keychain create/read, password replacement, and deletion with a disposable account. Standalone test runners lack the app’s Keychain entitlements, so unit checks use an in-memory credential store.
- The iPad form was checked for a default-off Remember control and readable scrolling. Full relaunch/Forget UI verification was interrupted by simulator use; the disposable beta-grid fixture was removed. No verification credentials were submitted to a live grid.

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
