# Parallel renderer controls

Display → Rendering offers three additional saved preferences:

| Control | Default | Behavior |
|---|---|---|
| Render threads | 1 | Use 1–3 threads within one captured frame. Large pixel operations are divided into disjoint row bands, with a barrier between compositor layers. |
| Parallel viewport scaling | Off | Divide captured original-map-size viewport scaling among those threads. Requires parallel rendering and at least two render threads. |
| Direct frame output | Off | Present an immutable completed worker Surface through its native image DC without copying it into the engine's Surface first. |

Changes apply immediately and are stored in the existing `:display` NVRAM section
as `:render_threads`, `:parallel_stretch`, and `:direct_output`. They restore on a
new process or F12. Missing values keep the defaults; invalid saved values are
ignored, and older DLLs without these APIs retain their existing renderer mode
controls. Switching thread count or scaling policy drains the old queue before
changing its resources.

The direct output path retains the completed Surface while GDI reads it and calls
`GdiFlush` before releasing its DC. Target recycling requires exclusive ownership.
Strip rendering, ordinary snapshots, freeze and unsupported viewport effects
retain their existing paths. Steam still draws into its independent CPU copy.
Automatic full Screen jobs omit the old destination/background copies because
Screen clears the entire target; manual and partial APIs still preserve it.

Ruby callers can use `ModLoader::ParallelRenderer.workers=`,
`parallel_stretch=`, and `direct_output=` to apply and save the same preferences.
Native setters remain available for temporary diagnostic changes.

Validation includes full RGBA comparisons, independent GDI source RGB checks,
odd clips and fractional scaling, alpha/tone/blend/Plane cases, snapshots and
menu backgrounds, freeze/transition comparison, saved settings and F12 recovery.
Native fixtures are in `tests/renderer_*_rgss.rb`; host menu tests are in
`tests/modloader_display_test.rb`.
