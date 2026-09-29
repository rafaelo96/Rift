# Classic Super Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional, real-time classical super-resolution mode that improves perceived detail without copying, transcoding, or rewriting the source video.

**Architecture:** `Rendering` owns a bounded Metal processor that upscales decoded bi-planar frames before `CMSampleBuffer` creation. Motion estimation and Frame+ remain unchanged. After isolated rendering validation and commit, `UI` exposes the renderer setting through the existing Visual panel.

**Tech Stack:** Swift, Metal compute, CoreVideo pixel-buffer pools, AVSampleBufferDisplayLayer, SwiftUI.

## Global Constraints

- The source file is never copied, transcoded, or rewritten.
- No neural networks, pretrained models, Core ML, MLX, or PyTorch.
- No new external dependencies.
- Memory is bounded by `CVPixelBufferPool`; maximum output is 3840×2160.
- Preserve bi-planar 8-bit/10-bit formats and all propagating HDR/color attachments.
- If processing fails or misses the safety policy, return the original frame rather than interrupt playback.

---

### Task 1: Rendering processor and isolated validation

**Files:**
- Create: `Rendering/Swift/SuperResolutionProcessor.swift`
- Create: `Rendering/Swift/SuperResolutionShaders.swift`
- Modify: `Rendering/Swift/HDRDisplayRenderer.swift`
- Modify/Test: `Rendering/Tools/AdmissionCheck.swift`

**Interfaces:**
- Produces: `SuperResolutionMode: String, CaseIterable, Sendable` with `off`, `soft`, `balanced`, `strong`.
- Produces: `SuperResolutionProcessor.process(_ input: CVPixelBuffer, mode: SuperResolutionMode) -> CVPixelBuffer?`.
- Produces: `HDRDisplayRenderer.superResolutionMode` and `setSuperResolutionMode(_:)`.

- [x] Add a failing rendering check asserting 1280×720 becomes 2560×1440, 1920×1080 becomes 3840×2160, 4K remains 4K, pixel values do not overshoot their local range, and attachments propagate.
- [x] Implement a reusable Metal pipeline: edge-directed luma reconstruction plus clamped detail recovery; bilinear chroma reconstruction; zero per-frame unbounded allocations.
- [x] Integrate processing before `CMVideoFormatDescriptionCreateForImageBuffer`, with original-buffer fallback on failure.
- [x] Run the isolated rendering admission check and `swift build -c release`; measured on the development Mac M4: 720p 1.32 ms, 1080p 2.18 ms, and 4K 2.56 ms. These measurements are not generalized to other chips; the processor measures live cost and temporarily bypasses itself after repeated budget misses.
- [x] Commit only `Rendering/` plus this plan.

### Task 2: Visual panel integration

**Files:**
- Modify: `UI/Player/RiftPlayerState.swift`
- Modify: `UI/PlayerControlsView.swift`
- Modify: `UI/Preview/PlayerStatePreviewStub.swift`

**Interfaces:**
- Consumes: `HDRDisplayRenderer.setSuperResolutionMode(_:)`.
- Produces: persisted `superResolutionMode`, selectable from the existing Visual controls.

- [ ] Add state and preference persistence with default `off`.
- [ ] Add an accessible segmented selector Off/Suave/Equilibrado/Fuerte to the existing Visual popover without redesigning it.
- [ ] Ensure reset restores `off`, renderer recreation reapplies the selection, and the Visual button reflects super-resolution activity.
- [ ] Run the release build and a 60-second 1080p playback probe with Frame+ on and off.
- [ ] Commit the `UI/` integration separately.

### Task 3: End-to-end acceptance

**Files:**
- Modify only if a measured defect requires a scoped correction in the owning module.

- [ ] Compare disabled/enabled captures on the reported anime scene at 18:07.
- [ ] Verify 60 fps admission and presentation remain stable with Frame+ plus Balanced super-resolution.
- [ ] Verify 4K input is not enlarged and HDR attachments remain present.
- [ ] Confirm `git diff --check`, clean status, and document measured limitations.
