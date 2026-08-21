# Nightfall — Android XR Port: Living Status Document

**Status as of 2026-08-16: Phase 0 (repository audit) complete, including research follow-up
that resolved the plugin-version/SDK-level/passthrough-extension unknowns from §7 items 1–3
against official Google/Godot sources. No code changes made yet.**

This document is maintained continuously during the Android XR port. It reflects the current
state of understanding and implementation — update it whenever a decision, blocker, or milestone
changes. Individual decisions and their rationale live in `decisions.md`; this document is the
map, status board, and how-to.

---

## 1. Goal

Port Nightfall from Meta Quest / Android OpenXR to also run natively on **Android XR**,
initially targeting a specific Android XR device (referred to throughout as "the target
device"), while:

- preserving existing GameStream functionality (Sunshine / Apollo / Vibepollo compatibility),
- preserving existing Meta Quest support,
- reusing Nightfall's architecture rather than forking it,
- protecting the low-latency zero-copy Android video path above all else.

First success criterion (unchanged from the task brief): *Nightfall launches natively in
immersive Android XR on the target device, connects to a Vibepollo/Apollo host, starts a GameStream
session, and renders the decoded PC image on a head-tracked spatial screen with working gamepad
input and audio.*

---

## 2. Current architecture (as audited)

Nightfall is a Godot 4.7 (Forward+, OpenXR) application with a native GDExtension for
performance-critical streaming/decode work.

```
main.gd (thin coordinator, ~1600 lines: state, _ready, _process, _input, XR bring-up)
  ├── src/stream_manager.gd       — pairing/streaming lifecycle, audio, texture binding, stats
  ├── src/xr_interaction.gd       — raycasts, grab bars, corner resize, UI clicks
  ├── src/input_handler.gd        — keyboard/mouse/controller forwarding
  ├── src/controller_mapper.gd    — Quest controller → virtual Xbox pad / KBM mapping
  ├── src/composition_layer_manager.gd — OpenXR composition layers (cylinder/quad) + mesh fallback
  ├── src/screen_manager.gd       — corner handles, bezel, curvature
  ├── src/settings_controller.gd  — passthrough, display refresh rate, filters
  ├── src/depth_estimator.gd      — AI stereoscopic 3D (MiDaS/Depth-Anything-V2 via TFLite)
  ├── src/ui_controller.gd, welcome_screen.gd, virtual_keyboard.gd, virtual_trackpad.gd, ...
  └── src/state_manager.gd, host_discovery.gd, wol_sender.gd, auto_detect.gd, background_manager.gd

addons/nightfall-stream/   — GDExtension (C++, built via CMake+Ninja+vcpkg)
  src/video/     — decode: FFmpeg (desktop) / raw NDK AMediaCodec (Android), zero-copy AHB→Vulkan
  src/audio/     — miniaudio-based playback
  src/input/     — controller/gamepad forwarding into moonlight-common-c
  src/network/   — pairing, mDNS discovery, HTTP
  (wraps moonlight-common-c for the GameStream/NVIDIA protocol)

android/src/main/java/com/godot/game/
  GodotApp.java        — loads the GDExtension .so, JNI handshake, Android context → FFmpeg JNI
  DepthEstimator.java  — TFLite/NNAPI inference wrapper for AI 3D

patches/godot-4.7-ahb.patch — custom Godot engine patch: Vulkan AHardwareBuffer import
                               (texture_create_from_android_hardware_buffer, texture_get_ycbcr_sampler)

addons/godotopenxrvendors/ — GodotOpenXRVendors plugin (NOT checked into git — gitignored,
                              installed via Godot AssetLib). Currently provides the Meta OpenXR
                              vendor loader/AAR. export_presets.cfg already shows this plugin
                              exposes Android XR as a vendor option too (see §5).
```

### Video path (critical — see §6 for the full trace)

```
GameStream H.264/HEVC/AV1 → moonlight-common-c decode-unit callback
  → (Android) raw NDK AMediaCodec, output surface = AImageReader
  → AHardwareBuffer (zero-copy)
  → Vulkan import via godot-4.7-ahb.patch (VK_ANDROID_external_memory_android_hardware_buffer
     + VkSamplerYcbcrConversion for NV12)
  → SPIR-V compute shader: YCbCr → RGBA (GPU-side, no CPU copy)
  → Godot Texture2DRD, bound to composition-layer / mesh shader material
  → OpenXRCompositionLayerCylinder/Quad (or mesh fallback) → OpenXR runtime compositor → headset
```

This is already a zero-copy pipeline on Android, and it is **already generic Android/Vulkan
code, not Meta-specific** (see §5). This is the single most important subsystem to leave alone.

---

## 3. Environment note (this audit session)

This audit was performed in a remote sandbox with **no Godot editor/headless binary, no Android
SDK/NDK, no `vcpkg`, no Android/Android XR device or emulator, and no Docker daemon**. Present:
`cmake` 3.28, `ninja` 1.11, OpenJDK 21, Gradle 8.14.3, network access via an outbound proxy.

**Consequence**: Phase 1 ("build in existing supported configuration, verify a baseline APK") and
Phase 3 on-device testing could not be executed in this session. Everything below is static code
review (direct file reading plus three parallel deep-dive audits of the GDExtension/video
pipeline, the Android native/Gradle layer, and the GDScript XR/Meta-extension surface). No
compilation, export, or install was attempted, and none is claimed. See §9 for exactly what a
developer with proper tooling needs to run to close this gap.

---

## 4. Architectural map — portability classification

Legend: **Portable** (should work unchanged) / **Probably portable** (generic API, needs
on-device testing) / **Quest-specific** (needs conditional or replacement) / **Blocker** (will
prevent build/launch/runtime on Android XR until changed).

| # | Component | File(s) | Classification | Notes |
|---|---|---|---|---|
| 1 | NDK `AMediaCodec` decode + `AImageReader` | `addons/nightfall-stream/src/video/mediacodec_native.cpp/.h` | **Portable** | Pure AOSP NDK API, no Meta dependency. Android-only decode path already bypasses FFmpeg by design (comment at `stream_connection.cpp:629`). |
| 2 | AHardwareBuffer → Vulkan zero-copy import | `patches/godot-4.7-ahb.patch`, `stream_connection.cpp:1195-1265` | **Portable** | Gated by generic `ANDROID_ENABLED`, not any Quest/OVR symbol. Relies on `VK_ANDROID_external_memory_android_hardware_buffer`, a near-universal Android Vulkan 1.1+ extension. |
| 3 | YCbCr→RGBA compute shader, `TextureUploader` | `addons/nightfall-stream/src/video/texture_uploader.cpp`, `ycbcr_to_rgba.comp` | **Portable** | Generic Vulkan/RenderingDevice code. |
| 4 | Tier-1 JNI MediaCodec fallback (H.264 HW-upgrade) | `addons/nightfall-stream/src/video/ffmpeg_decoder.cpp:38-88`, `mediacodec_internal.h` | **Probably portable** | Standard `android.media.MediaCodec` JNI reflection; secondary/legacy path, low test priority for MVP. |
| 5 | vcpkg dependency set (ffmpeg, curl, godot-cpp, moonlight-common-c, opus, openssl) | `addons/nightfall-stream/vcpkg.json` | **Portable** | Nothing Quest-locked; only the `arm64-android` triplet matters, which Android XR devices share. |
| 6 | `AndroidMediaCodec`/AHB buffer-id cache fallback for old API levels | `mediacodec_native.cpp:1226-1228` | **Portable** | Comment mentions "older Quest OS releases" but logic keys off Android API level via `dlsym`, not device identity. |
| 7 | `GodotApp.java` JNI bootstrap, lifecycle | `android/src/main/java/com/godot/game/GodotApp.java` | **Portable** | Generic `GodotActivity`/JNI plumbing; no Meta SDK classes. Multicast lock for mDNS is standard Android. |
| 8 | `DepthEstimator.java` (TFLite/NNAPI AI-3D) | `android/src/main/java/com/godot/game/DepthEstimator.java` | **Portable** | No Meta API. Gated by `OS.get_name() == "Android"` in GDScript, not a Quest check — despite README calling it "Quest only." |
| 9 | `android/build.gradle` `MergeNativeLibsTask` openxr_loader dedup hook | `android/build.gradle:222-241` | **Portable** | Keys off the generic `"godotopenxr-"` path substring; will apply equally to a future Android XR vendor AAR. |
| 10 | `src/openxr_action_map.tres` | whole file | **Portable** | 11 interaction profiles including generic `khr/simple_controller` (line 200) and `ext/hand_interaction_ext` (line 1740) fallbacks — not locked to Oculus Touch. |
| 11 | `src/xr_interaction.gd`, `input_handler.gd`, `controller_mapper.gd` | whole files | **Portable** | Driven by action-map action names (`trigger`, `grip`, `ax_button`, ...) and core `XRController3D`/`Input` APIs. |
| 12 | Passthrough (`_init_xr`, `apply_passthrough`) | `main.gd:820-841`, `settings_controller.gd:76-91` | **Portable logic / Quest-specific enablement flag** | Uses only core `XRInterface.get_supported_environment_blend_modes()` + `XR_ENV_BLEND_MODE_ALPHA_BLEND`. No `XR_FB_passthrough`/vendor calls in GDScript. But `project.godot:48`'s `openxr/extensions/meta/passthrough=true` is what makes Quest's runtime advertise alpha-blend at all — Android XR's equivalent enablement path is unconfirmed (see §7). |
| 13 | Hand tracking | `main.gd:21-38,1064-1093`, `xr_interaction.gd` | **Portable** | Core `XR_EXT_hand_tracking` via `XRHandTracker`; `project.godot:46`'s `openxr/extensions/hand_tracking=true` is the generic toggle (distinct from the Meta passthrough flag right below it). Not MVP-critical (see task brief). |
| 14 | `src/composition_layer_manager.gd` | whole file | **Probably portable** | Uses Godot-core `OpenXRCompositionLayerCylinder`/`Quad` (not `XR_FB_composition_layer_*`), with `is_natively_supported()` checks and an automatic mesh-rendering fallback already built in. Needs on-device confirmation that Android XR's runtime supports/behaves well with these layer types. |
| 15 | `src/state_manager.gd`, `vr_panel_base.gd`, `background_manager.gd`, `ui_controller.gd`, `virtual_keyboard.gd`, `virtual_trackpad.gd`, `wol_sender.gd`, `auto_detect.gd`, `host_discovery.gd` | whole files | **Portable** | No Meta/vendor XR calls found. |
| 16 | Meta Quest Touch Plus controller models | `main.gd:1330-1354`, `models/controllers/MetaQuestTouchPlus_*.fbx` | **Quest-specific** | Hardcoded asset paths; loads silently return null off-Quest (`load()` returns null → no crash) but no Android XR controller model exists yet. Cosmetic only — not an MVP blocker. |
| 17 | `enable_meta_plugin=true` + `meta_xr_features/*` in both Android export presets | `export_presets.cfg:238-253,499-514` | **Quest-specific** | Actively drives today's manifest/AAR selection. Needs a parallel Android XR preset, not a modification of these. |
| 18 | `godotopenxr-meta-{debug,release}.aar` staging | `build.sh:184,187` | **Quest-specific / blocker for AXR build** | Hardcoded filenames; an Android XR export needs the equivalent Android XR vendor AAR staged instead (or in addition). |
| 19 | `addons/godotopenxrvendors/` plugin itself | not in repo (gitignored) | **Confirmed available upstream — must verify local install** | Official Google/Godot Foundation/W4 Games partnership shipped Android XR support in **GodotOpenXRVendors plugin v5.1** (May 2026, requires Godot 4.6.2+). The locally-installed copy in this repo's environment must be updated to v5.1+ via the Godot AssetLib and its `.bin/android/` inspected for the exact Android XR AAR filename before `build.sh` can stage it. See `ANDROID_XR_PORT.md` §7 item 1. |
| 20 | `min_sdk="29"` / `target_sdk="32"` | `export_presets.cfg:34-35,292-293` | **Confirmed blocker for a new Android XR preset (Quest presets are fine as-is)** | Official requirement (developer.android.com/develop/xr/godot/setup): **Min SDK 34, Target SDK 34**, Build-Tools 34.0.0+, **NDK 28.x** (Quest build currently pins NDK 27.0.12077973 — a separate toolchain, not just an SDK bump). The new `NightfallAndroidXR` preset must set these explicitly; do not change the existing Quest presets. See §7 item 3. |
| 21 | No checked-in `AndroidManifest.xml` | n/a | **Neutral** | Godot generates/merges the manifest at export time from the export template + `export_presets.cfg` options + whichever vendor plugin(s) are enabled. All XR-permission wiring flows through the preset config and the vendor plugin, not a static file to migrate. |
| 22 | `AI 3D mode` reachability | `main.gd:713`, `settings_controller.gd` (per `performance-hypotheses-2026-07-08-fable.md:261`) | **Pre-existing bug, not Android-XR-related** | `ai_3d_mode` is clamped to `[0,1]` but `apply_stereo()` reportedly only activates the depth estimator at mode ≥ 3 — appears to be currently-unreachable code on Quest too. Flagged here for awareness; **not in scope for the Android XR port**, do not fix opportunistically (working rule 1). Needs independent confirmation before treating as fact. |

**Overall read**: the codebase is far more "generic OpenXR/Android" than "Meta Quest" already.
The genuinely Quest-specific surface is narrow: the export-preset vendor-plugin selection, the
`meta/passthrough` project-setting extension flag, the bundled Meta AAR, and cosmetic controller
model assets. None of the streaming/decode/GameStream core needs to change.

---

## 5. Quest-specific dependencies discovered → Android XR replacement plan

| Quest dependency | Where | Android XR replacement |
|---|---|---|
| `xr_features/enable_meta_plugin=true` + `meta_xr_features/*` | `export_presets.cfg` presets 0 & 1 | New `[preset.3] NightfallAndroidXR` with `xr_features/enable_androidxr_plugin=true` and the existing (currently inert) `android_xr_features/*` block populated appropriately. Leave presets 0/1 untouched. |
| `godotopenxr-meta-{debug,release}.aar` | `build.sh:184,187` | Extend `build.sh` to stage the Android-XR-vendor AAR from `addons/godotopenxrvendors/.bin/android/` when building the new preset (exact AAR name TBD — must be confirmed once the plugin is installed locally; likely `godotopenxr-androidxr-{debug,release}.aar` or similar, following the existing per-vendor naming convention). |
| `openxr/extensions/meta/passthrough=true` | `project.godot:48` | Nightfall's passthrough code only needs core `XR_ENV_BLEND_MODE_ALPHA_BLEND` (§7 item 2) — likely needs **no** Android XR-specific project-setting flag at all, since that's core OpenXR 1.0, not a vendor extension. **Confirm on-device**; do not add speculative extension flags before testing. |
| `MetaQuestTouchPlus_{Left,Right}.fbx` controller models | `main.gd:1330-1354`, `models/controllers/` | Not MVP-critical. Long-term: gate model loading on a detected platform/vendor (e.g. `OS.get_name()`/interaction-profile check) and either supply an Android XR controller model or fall back to the existing generic laser/hand visualization already in `main.gd` (`_create_hand_visualizer`), which requires no controller mesh at all. |
| `min_sdk=29` / `target_sdk=32`, NDK 27.0.12077973 | `export_presets.cfg`, `BUILD.md` | New `NightfallAndroidXR` preset only (do not touch the Quest presets): `min_sdk="34"`, `target_sdk="34"`, Android SDK Build-Tools 34.0.0+, and a separate **NDK 28.x** toolchain (confirmed requirement, source: developer.android.com/develop/xr/godot/setup — see §7 item 3). |
| Two Meta-only permissions implicitly injected by the vendor plugin at export time (not visible in `export_presets.cfg`'s generic `permissions/*` block) | vendor plugin manifest fragment | N/A for Android XR preset — simply don't enable the Meta plugin there; whatever manifest fragment the Android XR vendor plugin injects instead is out of this repo's control and should be captured by inspecting the generated manifest after a real export. |

Nothing above requires touching `addons/nightfall-stream/` (the GDExtension/video pipeline) or
the GameStream protocol/session code at all.

---

## 6. Video path — full trace (protect this)

```
1. Network: GameStream RTP stream → moonlight-common-c decode-unit callback
   addons/nightfall-stream/src/video/stream_connection.cpp:793 (_cb_submit_decode_unit)

2. Platform dispatch (Android takes a DIFFERENT path than desktop — by design):
   stream_connection.cpp:608 (_cb_decoder_setup)
   Comment at stream_connection.cpp:629: "Android: ONLY native NDK MediaCodec + ImageReader
   for zero-copy GPU decode. No FFmpeg fallback."
   → constructs AndroidMediaCodec, stream_connection.cpp:672-696

3. NDK AMediaCodec decode (Android only):
   mediacodec_native.cpp:44-146  AndroidMediaCodec::init()
     - AImageReader created with AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE (:59-64)
     - ANativeWindow from the ImageReader passed as MediaCodec output surface (:94, :126)
   Packet feed: stream_connection.cpp:1145-1156 → mediacodec_native.cpp:329-377
   Frame out:   mediacodec_native.cpp:379-501 (dequeue_frame)
     - AMediaCodec_releaseOutputBuffer(..., true) → AImageReader_acquireLatestImage
       → AImage_getHardwareBuffer()  == zero-copy handoff to AHardwareBuffer*

4. AHardwareBuffer → Vulkan import (zero-copy):
   stream_connection.cpp:1195-1265 (_get_or_create_ahb_import)
     calls rd->call("texture_create_from_android_hardware_buffer", ...)
     and   rd->call("texture_get_ycbcr_sampler", ...)
   — these two RenderingDevice methods exist ONLY because of the custom engine patch:
   patches/godot-4.7-ahb.patch
     - RenderingDeviceDriverVulkan::texture_create_from_android_hardware_buffer()
       (vkGetAndroidHardwareBufferPropertiesANDROID, VkSamplerYcbcrConversion for NV12,
       VkExternalMemoryImageCreateInfo/VkImportAndroidHardwareBufferInfoANDROID — no CPU copy)
     - sampler_create_from_texture() — matching YCbCr-aware VkSampler
     - Bound to GDScript/GDExtension via servers/rendering/rendering_device.cpp ClassDB::bind_method

5. GPU-side colorspace conversion:
   stream_connection.cpp:115-179 (_ensure_compute_pipeline) runs a SPIR-V compute shader
   (ycbcr_to_rgba.comp / ycbcr_to_rgba_spirv.h) converting YCbCr → RGBA8, writing into
   rgba_output_tex_ (stream_connection.cpp:142). Still zero CPU copies.

6. Godot texture surfacing:
   texture_uploader.cpp:24-76 (TextureUploader::set_texture_from_native_rid)
     wraps the RD texture RID via RenderingServer::texture_rd_create() into a Texture2DRD.

7. GDScript binding:
   src/stream_manager.gd:292 (_setup_v2_yuv_rect) — flat-mesh path
   src/composition_layer_manager.gd:511-563 (bind_yuv_textures / bind_comp_yuv_textures)
     — re-binds tex_y/tex_u/tex_v shader params onto both the flat-mesh material and the
       composition-layer shader materials (comp_shader_mat, _left, _right)

8. Display:
   src/composition_layer_manager.gd:36-46 creates OpenXRCompositionLayerCylinder/Quad
   (Godot-core OpenXR classes) if is_natively_supported(), else falls back to
   switch_to_mesh_rendering() (composition_layer_manager.gd:633-665).
   → OpenXR runtime compositor → headset.
```

**Portability verdict**: every hop above is generic NDK/Android/Vulkan/core-OpenXR code. The
only unverified assumption is whether the target Android XR device's Vulkan ICD implements
`VK_ANDROID_external_memory_android_hardware_buffer` with NV12 YCbCr sampler support — the
current code only checks `rd->has_method(...)` (i.e., whether Godot itself was built with the
patch), **not** whether the driver actually supports the extension
(`stream_connection.cpp:1195`). This should be checked defensively and logged, not assumed, when
Phase 3 work begins (see §10, "Debugging").

**Do not**: replace this with software decoding, add an extra CPU-side copy, or route video
through a different composition mechanism "to get something on screen faster." If the AHB/Vulkan
import path fails to initialize on Android XR hardware, the correct response is to find out why
(log the actual Vulkan error) — see §10 — not to fall back to a slower path silently.

---

## 7. Known problems / open questions

Items 1–3 below were static-review unknowns at the Phase 0 audit and have since been **resolved
by research** (web search against Google's official Android XR developer docs and the Godot/AXR
ecosystem, 2026-08-16 — see `decisions.md` for the dated entry and sources). Items 4–7 remain
genuinely unresolvable without a device/build and are tracked as before.

1. **RESOLVED — GodotOpenXRVendors plugin Android XR support is real and official.** Google, the
   Godot Foundation, and W4 Games announced official Godot support for Android XR (Godot 4.6.2+)
   in partnership, and **GodotOpenXRVendors plugin v5.1** (released May 2026) is the version that
   ships Android XR vendor support — trackables/spatial entities, depth texture extensions,
   device anchor persistence, raycasting, and mouse interaction, alongside the existing Meta
   loader. Source: developer.android.com/develop/xr/godot, developer.android.com/develop/xr/godot/setup.
   **Verified on a dev machine 2026-08-20** (Windows 11, Godot 4.7.1, plugin installed via
   in-editor AssetLib):
   - The **Android XR vendor toggle exists and works** — setting it in the export dialog writes
     `xr_features/enable_androidxr_plugin=true`.
   - The Android XR AAR filenames are confirmed as **`godotopenxr-androidxr-debug.aar`** and
     **`godotopenxr-androidxr-release.aar`**, in
     `addons/godotopenxrvendors/.bin/android/{debug,release}/` — matching the existing
     `godotopenxr-meta-*` convention. The plugin ships loaders for androidxr, khronos, lynx,
     magicleap, meta, and pico, plus `openxr-validation-layers-*.aar`.
   - The `android_xr_features/*` option set the plugin exposes is **identical** to the five keys
     already present in this repo (`eye_tracking`, `hand_tracking`, `tracked_controllers`,
     `recommended_boundary_type`, `use_experimental_features`) — no new export options, so
     hand-editing `export_presets.cfg` is safe.
   - The plugin is a **GDExtension** (`plugin.gdextension` + per-platform binaries), not a
     script-based `EditorPlugin`, so it does *not* appear under Project Settings → Plugins and
     needs an editor restart after install to register.

   **Still open**: the precise installed plugin *version number* has not been read off disk. The
   identical option set is consistent with either v5.1 or an older release, so this should be
   confirmed before trusting Android XR runtime behavior.
2. **RESOLVED ON DEVICE — passthrough needs no vendor extension.** Confirmed 2026-08-20:
   `main.gd:824` logged `[XR] Blend modes: [0, 1, 2]`, and `2` is
   `XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND`. The Android XR runtime advertises alpha-blend
   with **no** `openxr/extensions/...` project setting and no Android XR passthrough extension
   requested, unlike Quest, where the Meta runtime only advertises it when `XR_FB_passthrough`
   is enabled via `project.godot:48`. Nightfall's existing passthrough code therefore needs no
   change. The original analysis follows.

   **RESOLVED (with nuance) — passthrough enablement.** Android XR's official OpenXR extension
   docs (developer.android.com/develop/xr/openxr/extensions) model passthrough differently from
   Meta's single `XR_FB_passthrough` flag: `XR_ANDROID_composition_layer_passthrough_mesh` (needs
   the `SCENE_UNDERSTANDING_COARSE` runtime permission) is for compositing passthrough onto
   arbitrary geometry, and `XR_ANDROID_depth_texture`/`light_estimation` (need
   `SCENE_UNDERSTANDING_FINE`) are for advanced mixed-reality features — none of which Nightfall
   currently uses. Nightfall's actual passthrough implementation (`main.gd:820-841`,
   `settings_controller.gd:76-91`) only queries `get_supported_environment_blend_modes()` and
   sets `XR_ENV_BLEND_MODE_ALPHA_BLEND`, which is **core OpenXR 1.0**, not a vendor extension — so
   it may work with **zero** Android XR-specific extension enablement or manifest permission,
   unlike on Quest where the Meta runtime only advertises alpha-blend when `XR_FB_passthrough` is
   requested via the `openxr/extensions/meta/passthrough=true` project setting. **Still an
   assumption needing on-device confirmation**: whether Android XR's runtime advertises
   `ALPHA_BLEND` with no extension request at all, or requires some minimal Android XR extension
   to be requested even for basic blend-mode passthrough, isn't stated in the docs reviewed and
   must be logged/tested in Phase 3 (see §10 debug logging plan).
3. **RESOLVED — min/target SDK, and a new NDK finding.** Official Android XR requirements
   (confirmed on developer.android.com/develop/xr/godot/setup): **Min SDK 34, Target SDK 34**,
   Android SDK Build-Tools 34.0.0+, and — a new finding not in the original audit — **NDK: any
   28.x version** (Nightfall's `BUILD.md` currently pins **NDK 27.0.12077973** for the Quest
   build; the new Android XR preset needs a separate/updated NDK — a genuine build-tooling
   difference between the two targets, not just an SDK-level bump). This confirms
   `export_presets.cfg`'s current `min_sdk="29"`/`target_sdk="32"` (both presets) are far below
   what an Android XR preset needs; the new `NightfallAndroidXR` preset must set `min_sdk="34"`,
   `target_sdk="34"` explicitly and **not** touch the existing Quest presets' values (Quest still
   works fine at 29/32). Also newly confirmed: the official Godot Android XR setup guide
   recommends the **Mobile** renderer and `MSAA 3D: 4x`; Nightfall currently ships with
   `config/features=PackedStringArray("4.7", "Forward Plus")` (`project.godot:20`) and explicitly
   disables MSAA on Android (`main.gd:846`, for the 4K-performance reasons documented in
   `doc/4k-performance-optimization.md`). Since Nightfall already runs Forward+ successfully on
   Quest's mobile Adreno GPU, this is flagged as a **compatibility risk to test**, not a confirmed
   blocker — do not switch renderers preemptively (working rule 1); only revisit if Forward+
   demonstrably fails or underperforms on Android XR hardware.
4. **Does the target device's Vulkan ICD implement
   `VK_ANDROID_external_memory_android_hardware_buffer`?** Assumed yes (near-universal on modern
   Android GPUs) but must be confirmed via device logs, not assumed. Unresolved — requires device.
5. **RESOLVED ON DEVICE — composition layers are natively supported.** Confirmed 2026-08-20:
   `composition_layer_manager.gd` logged `[COMP] Cylinder layer natively supported` and created
   the cylinder, UI, cursor and keyboard layers, so `is_natively_supported()` returned true and
   the mesh-rendering fallback was not used. Visual quality and latency under an actual stream
   are still unmeasured. Also confirmed working: OpenXR stereo rendering at a 1920x1200 render
   target (`main.gd:823`) and the display refresh-rate API (`settings_controller.gd`, set to
   72Hz).
6. **AI 3D mode reachability** (`ai_3d_mode` clamped to `[0,1]` vs. `apply_stereo()` gating at
   `>= 3`, per `performance-hypotheses-2026-07-08-fable.md:261`) — appears to be a pre-existing
   issue unrelated to this port; confirm independently before acting, and if real, it's out of
   scope for the Android XR port (do not fix opportunistically).
7. **Does Godot 4.7's patched-engine requirement (custom AHB template) also need building for
   whatever Android XR uses as its runtime/loader?** The patch itself is generic Android/Vulkan
   (§6), so the same custom-patched `libgodot_android.so` templates built for Quest should work
   for Android XR — but building it will require the newer NDK 28.x + API 34 toolchain per item 3
   above, not the NDK 27/API-29 toolchain the Quest templates were built with, and this has not
   been confirmed by an actual Android XR build/run.

---

## 8. Target architecture (where the port is headed)

```
Nightfall
│
├── GameStream core                         (UNCHANGED — reuse entirely)
│   ├── discovery      → src/host_discovery.gd, addons/nightfall-stream/src/network/
│   ├── pairing         → addons/nightfall-stream/src/network/, src/stream_manager.gd
│   ├── session         → addons/nightfall-stream/src/video/stream_connection.cpp
│   ├── video            → addons/nightfall-stream/src/video/ (MediaCodec/AHB/Vulkan path)
│   ├── audio            → addons/nightfall-stream/src/audio/
│   └── input             → addons/nightfall-stream/src/input/, src/input_handler.gd
│
├── Shared XR layer                          (UNCHANGED — already vendor-neutral)
│   ├── OpenXR            → project.godot [xr], main.gd _init_xr()
│   ├── screen geometry     → src/screen_manager.gd
│   ├── spatial transforms   → src/xr_interaction.gd
│   └── common interaction    → src/openxr_action_map.tres, src/controller_mapper.gd
│
└── Platform capabilities                    (NEW split — currently Meta-only, needs branching)
    ├── Meta Quest (existing, keep working)
    │   ├── enable_meta_plugin export preset
    │   ├── MetaQuestTouchPlus controller models
    │   └── openxr/extensions/meta/passthrough flag
    │
    └── Android XR (new — Phase 3 target)
        ├── enable_androidxr_plugin export preset (new NightfallAndroidXR preset)
        ├── Android XR passthrough enablement (TBD — §7 item 2)
        └── Android XR platform behavior / SDK levels (TBD — §7 item 3)
```

Note how small the "Platform capabilities" box is relative to the rest of the app — this
reflects the audit finding that Nightfall's XR integration was already written against
Godot/OpenXR-core APIs, with Meta-specific surface confined almost entirely to export
configuration and cosmetic assets rather than game logic.

---

## 9. Build instructions

### What BUILD.md documents (Quest, existing, unverified in this session)

See `BUILD.md` for the full authoritative process. Summary of prerequisites: Godot 4.7 Beta 2
(editor + patched export templates), Android NDK 27.0.12077973, JDK 17, vcpkg, Ninja, ADB, and
the GodotOpenXRVendors plugin installed via the Godot editor's Asset Library.

```bash
# GDExtension (Android/Quest)
cd addons/nightfall-stream
export VCPKG_ROOT=~/Development/Personal/vcpkg
export VCPKG_DEFAULT_TRIPLET=arm64-android
export ANDROID_NDK_HOME=/path/to/ndk/27.0.12077973
export ANDROID_ABI=arm64-v8a
cmake --preset android
ninja -C build/android

# APK export
./build.sh --debug            # or --release, --install
```

**This was not run in this session** — see §3. A developer/CI runner with the above tooling
should run this exact sequence and record the actual result (success/failure, exact error text)
in this section before Phase 1 can be marked complete.

### Planned Android XR build path (Phase 3, not yet implemented)

**Confirmed prerequisites** (source: developer.android.com/develop/xr/godot/setup, 2026-08-16 —
see `decisions.md`), in addition to everything `BUILD.md` already lists:

- Godot Engine 4.6.2+ (project is on 4.7, which satisfies this)
- **GodotOpenXRVendors plugin v5.1 or higher** (must be confirmed/updated locally — see §7 item 1)
- Android SDK Platform 34 ("UpsideDownCake"), Build-Tools 34.0.0+
- **NDK: any 28.x version** — separate from the NDK 27.0.12077973 pinned for the Quest build
- CMake 3.10.2+ (already satisfied — this environment has 3.28)
- Export preset: Min SDK 34, Target SDK 34, XR Mode = OpenXR

```bash
# GDExtension build — same command, but must be built with the NDK 28.x toolchain above,
# not the NDK 27 toolchain used for the Quest .so (the CMake/ninja invocation is otherwise
# platform-generic within Android; only the NDK path changes).
cd addons/nightfall-stream
export ANDROID_NDK_HOME=/path/to/ndk/28.x.x
cmake --preset android && ninja -C build/android

# Export using the new preset (exact build.sh flag TBD — will likely be `--androidxr`
# mirroring the existing `--debug`/`--release`/`--appimage` flags)
./build.sh --androidxr
```

This section will be filled in with the real flag name and any AAR-staging changes once Phase 3
work modifies `build.sh`.

---

## 10. Installation & testing procedure (Android XR, once a build exists)

> ### ⚠️ Log handling — read before pasting any device output
>
> Per the 2026-08-20 decision in `decisions.md`, the target device is not named in this
> repository. **Raw `adb` output identifies the device far more thoroughly than a product name
> does**, and the commands in this section produce exactly that kind of output:
>
> - `adb logcat` banners and `adb shell getprop` expose `ro.product.model`,
>   `ro.product.manufacturer`, `ro.build.fingerprint`, SoC and GPU driver versions
> - OpenXR initialization logs the runtime name and version
> - `adb devices` prints the hardware serial number
>
> **Rules for this repository:**
>
> 1. Never paste raw `logcat`, `getprop`, `dumpsys`, or `adb devices` output into a committed
>    file — including this document, debug notes, commit messages, issues, and PR descriptions.
> 2. When a log line needs to be recorded, record the **property, not the value**. Write
>    "the runtime advertises `XR_ENV_BLEND_MODE_ALPHA_BLEND`" or "`AHardwareBuffer` import
>    succeeded on first frame", not the version banner or fingerprint that carried that fact.
> 3. Redact before sharing outside the project — including with AI assistants operating on a
>    public repository, and in any bug report filed upstream (Godot, GodotOpenXRVendors,
>    moonlight-common-c), where the report itself is public.
> 4. If device-identifying output does get committed, treat it as disclosed: scrubbing the
>    working tree does not unpublish history that has already been served. Prefer prevention.
>
> This is a publication constraint only. It does not restrict what you may run locally, or what
> you may paste into a private chat while debugging — only what gets written down here.

```bash
adb devices                                   # confirm device visible (serial - do not record)
adb install -r Nightfall-AndroidXR-arm64-v8a-debug.apk
# GodotAppLauncher, not GodotApp: the latter is the inner activity and is not
# exported, so targeting it directly fails with a SecurityException. Confirm the
# entry point with: adb shell cmd package resolve-activity --brief <package>
adb shell am start -n app.nightfall.androidxr/com.godot.game.GodotAppLauncher
adb logcat -s NightfallXR:* GodotApp:* AndroidMediaCodec:* VCONN:*
```

On Windows the same commands run from PowerShell; `.\build.ps1 -Target androidxr -Install`
performs the install step for you.

Testing procedure (MVP checklist from the task brief — mark off as verified on real hardware):

- [ ] Application installs
- [ ] Application launches into immersive XR
- [ ] OpenXR initializes successfully (check logcat for the runtime name and enabled extensions —
      verify them, but record only *that* initialization succeeded, per the log-handling rules above)
- [ ] Head tracking works
- [ ] Nightfall UI is visible
- [ ] Host discovery / manual IP connect works
- [ ] Pairing works
- [ ] Stream starts
- [ ] Hardware video decode functions (check for AHB import success in logcat, not a fallback)
- [ ] Decoded video appears on the spatial screen
- [ ] Gamepad/Bluetooth input works
- [ ] Audio works
- [ ] Stream exits cleanly

None of these have been exercised yet — no Android XR build has been produced.

### Debug logging plan (Phase 3)

Prefix all new Android XR diagnostic logs `[NightfallXR]`, matching existing `_log()` calls in
`main.gd` and `NF_LOG` macros in the GDExtension (`addons/nightfall-stream/src/nf_log.h`). Log,
once each (not per-frame):
- Detected OpenXR runtime name/version and environment blend modes (extends the existing log at
  `main.gd:824`)
- Enabled vs. requested-but-unavailable OpenXR extensions
- Android XR capability detection results (passthrough, hand tracking, controller presence)
- Whether `VK_ANDROID_external_memory_android_hardware_buffer` is actually supported by the
  driver (not just whether Godot's `has_method()` check passes — see §6)
- Decoder init: selected codec, decoder surface creation success/failure, first decoded frame
  timestamp
- Spatial screen texture creation (composition layer vs. mesh fallback, and why)
- GameStream connection state transitions
- Input device enumeration (gamepad detected, controller profile bound)
- Audio device init

---

## 11. Current milestone

**Nightfall launches natively in immersive Android XR (2026-08-20).** The app installs, the
runtime grants it an immersive full-space slot, OpenXR initializes, and the UI renders in
headset. Confirmed on device by the developer; input was not yet working at that point (see
below).

Verified on device:

- [x] Application installs
- [x] Application launches into immersive XR — the runtime logs
      `Created immersive activity node` and `xrDesktopMode=full-space-unmanaged`
- [x] OpenXR initializes successfully — `libopenxr.google.so` loads, the `GodotOpenXR` plugin
      and `godotopenxrvendors` library initialize, Vulkan/Adreno comes up
- [x] Nightfall UI is visible
- [ ] Head tracking — not yet confirmed
- [ ] Input — no usable input path on first launch; hand tracking has since been enabled in the
      preset but is unverified
- [ ] Everything downstream of input (discovery, pairing, streaming, audio, exit) — untested
- [ ] Video — cannot work yet; the build uses the stock engine, so every decoded frame is
      dropped at `stream_connection.cpp:1195` (see §6 and task "patched engine")

Three defects were found and fixed getting here, none of them Android XR-specific — all three
would affect a fresh clone on any platform:

1. **The Android build template must be installed from the editor.** Unpacking
   `android_source.zip` is not equivalent: the editor also writes `settings.gradle`, the
   `gradlew` wrappers and `.gdignore`, and Godot rejects a raw extraction as "Android build
   template not installed". `BUILD.md` does not mention this step, and `build.sh:165-168`
   wipes and re-extracts the directory on every run — which only works because the upstream
   machine had a real install underneath.
2. **`android/.build_version` must match the running editor.** It was committed reading
   `4.7.stable`, so any other Godot version failed the same way. Now stamped by `build.ps1`
   and untracked.
3. **`GodotApp.java` only loaded the release-variant GDExtension.** A debug APK ships
   `template_debug`, so the load failed, the `catch (Throwable)` swallowed it, and the first
   native call in `onCreate` threw an uncaught `UnsatisfiedLinkError` that killed the app
   *after* OpenXR and Vulkan had already initialized.

Also missing from a fresh clone and reconstructed during this work: the
`nightfall-stream.gdextension` descriptor (absent from the repo entirely) and
`VCPKG_OVERLAY_TRIPLETS`, which is required for the custom `arm64-android` triplet but
undocumented.

## 12. Next steps

1. ~~Close the Phase 0 unknowns in §7~~ — items 1–3 (plugin version, passthrough extension
   requirements, SDK/NDK levels) resolved by research on 2026-08-16; remaining items 4–7 need a
   real device/build and stay open.
2. On a machine with the Godot editor installed: install/update GodotOpenXRVendors to **v5.1+**
   via the AssetLib and record its exact version and Android XR AAR filename(s) here.
3. **Phase 1** — run the documented `BUILD.md` process end-to-end on real tooling (Godot 4.7,
   NDK 27.0.12077973, vcpkg, patched engine templates) to establish that the *existing* Quest
   build is healthy before touching anything. Record exact commands/output here.
4. **Phase 3 minimum target** — once Phase 1's baseline is confirmed:
   - Add `[preset.3] NightfallAndroidXR` to `export_presets.cfg` (own package name, mirrors
     existing preset pattern) with `enable_androidxr_plugin=true`, `enable_meta_plugin=false`,
     `min_sdk="34"`, `target_sdk="34"`, and appropriate `android_xr_features/*` values.
   - Build the GDExtension a second time with an **NDK 28.x** toolchain (separate from the NDK 27
     toolchain used for Quest) and extend `build.sh` to stage the confirmed Android XR vendor AAR.
   - Build, install to the target device, and work through the testing checklist in §10 in order,
     starting with "application installs" / "launches into immersive XR" / "OpenXR initializes."
     Log whether alpha-blend passthrough works with no extra extension request (§7 item 2).
   - Only after basic streaming + gamepad + audio work (the MVP list in the task brief) should
     hand tracking, advanced passthrough, or any other stretch feature be attempted.
5. Keep this document and `decisions.md` updated at each step — do not let them go stale.

## 13. Future work (explicitly out of scope for the initial port)

Per the task brief, tracked here so it isn't lost, not scheduled:
- Apollo virtual display support, custom virtual resolutions, HDR, clipboard, host commands,
  virtual monitor lifecycle, multiple virtual displays/simultaneous streams (Artemis/Apollo
  features Nightfall doesn't yet expose).
- Hand tracking / gaze+pinch / advanced passthrough / AI depth estimation on Android XR / scene
  meshing / persistent anchors / multiple screens / eye tracking — all deferred past MVP per the
  task brief's explicit non-blocking list.
