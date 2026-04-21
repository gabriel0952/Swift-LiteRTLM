# LiteRT-LM Metal Sampler: No-Go Decision

Date: 2026-04-20

## Decision

The public LiteRT-LM Metal sampler path is **not practically recoverable** against the
public TensorFlow Metal runtime.

This document is the end-of-spike memo for the Metal sampler investigation.

## Evidence

### Easy fixes applied (spike pass 3)

Three compilation issues were resolved before reaching the stop conditions:

| Issue | Fix applied |
|---|---|
| `ComputeTask::Init(op, false)` → `Init(op)` | Dropped the `use_argument_buffer` arg |
| `GPUOperation::code_info_.uses_global_id = true` | Removed — field does not exist in public API |
| `ModelHints::kPreferTextureWeights` | Removed — hint not present in public API |

After these fixes the build error set reduced from 6 errors to exactly 4.

### Confirmed build errors after easy fixes

```
runtime/components/top_k_metal_sampler.mm:321
  error: no member named 'InitFromGpuModel' in 'tflite::gpu::metal::InferenceContext'

runtime/components/top_k_metal_sampler.mm:348
  error: no member named 'SetInt' in 'tflite::gpu::metal::ComputeTask'

runtime/components/top_k_metal_sampler.mm:364
  error: no member named 'SetFloat' in 'tflite::gpu::metal::ComputeTask'

runtime/components/top_k_metal_sampler.mm:545
  error: no member named 'InitFromGpuModel' in 'tflite::gpu::metal::InferenceContext'
```

Build command used to confirm:

```sh
cd Forks/LiteRT-LM/upstream
bazelisk build //runtime/components:top_k_metal_sampler
```

### Classification of remaining errors

#### `InferenceContext::InitFromGpuModel` (lines 321 and 545) — HARD STOP

The sampler calls `inference_context->InitFromGpuModel(create_info, &gpu_model, device)`.

The public `tflite::gpu::metal::InferenceContext` does not expose this method.
The public API only provides:

- `InitFromGraph(CreateGpuModelInfo, GraphFloat32, id<MTLDevice>)`
- `InitFromGraphWithTransforms(CreateGpuModelInfo, GraphFloat32*, id<MTLDevice>)`
- `RestoreDeserialized(serialized_model, id<MTLDevice>)`

Adapting to the public API would require:

1. Expressing the top-k sampling algorithm as a `GraphFloat32` — a TFLite-style
   operator graph
2. Using TFLite GPU delegate operator kernels to implement the top-k operation

The actual top-k GPU sampling kernel is defined inside the internal `ml_drift`
library and is **not present in the OSS tree**. No public TFLite GPU operator
covers this algorithm.

This is equivalent to implementing the Metal top-k sampler from scratch.
It is not build-graph recovery.

#### `ComputeTask::SetInt` / `ComputeTask::SetFloat` (lines 348 and 364) — MEDIUM

The sampler calls `compute_task->SetInt(name, value)` and
`compute_task->SetFloat(name, value)` to update scalar parameters before each
inference call.

The public `tflite::gpu::metal::ComputeTask` does not expose these methods.
`SetInt`/`SetFloat` are public methods on `tflite::gpu::metal::MetalArguments`,
which is a **private member** of `ComputeTask`.

A viable workaround exists in isolation:
- Create the params MTLBuffers with `MTLResourceStorageModeShared`
- Write scalar parameter values directly from CPU via `memcpy`
- This avoids the GPU write-params kernel pattern entirely

This workaround is **medium complexity** and would not be a rewrite.

However it is moot: the `InitFromGpuModel` stop condition is hit first and is not
resolvable without reimplementing the core sampling algorithm. The scalar param fix
would only matter if `InferenceContext` were usable.

## Root Cause Summary

The OSS `top_k_metal_sampler.mm` was authored against an internal `ml_drift`
API surface that is richer than the public TensorFlow Metal runtime in two ways:

1. **`InferenceContext` was extended internally** to accept a pre-built `GpuModel`
   directly, bypassing the `GraphFloat32` graph compilation path. That extension
   is not in OSS.

2. **The actual top-k GPU sampling kernels** are implemented inside `ml_drift`,
   not in the public TFLite GPU delegate operator library. Without these kernels,
   there is no real computation to put inside the `GpuModel`.

The first issue blocks compilation. The second issue blocks correctness even if
compilation were somehow achieved.

## Stop Conditions Met

From the spike plan:

> Stop this spike and document a no-go decision if any of the following becomes
> true:
>
> - `InferenceContext` adaptation requires rebuilding internal graph-construction
>   logic not present in OSS  ← **MET**
> - scalar param updates require intrusive rewrites across the sampler path  ← medium, workable in isolation
> - the Metal sampler can only be made to compile by reimplementing substantial
>   portions of internal `ml_drift`  ← **MET**

## What This Means For The Fork

The Metal top-k sampler path cannot be recovered from public OSS alone.
Options from here:

1. **Accept CPU sampling only** for the public fork. The LiteRT-LM CPU sampler
   path is intact in OSS and does not have these blockers.

2. **Implement a new Metal top-k kernel from scratch** using public Metal APIs.
   This is a significant scope expansion — it is new feature work, not
   build-graph recovery.

3. **Wait for upstream to publish the missing layer**. The `GpuModelBuilder` and
   the internal top-k kernels may be upstreamed in a future LiteRT-LM release.

The scope of this spike was limited to build-graph recovery. Option 2 is out of
scope. Option 1 or 3 are the realistic near-term paths.

## Files Modified In This Spike (all three passes)

- `Forks/LiteRT-LM/upstream/runtime/components/top_k_gpu_sampler.h` — added (scaffold)
- `Forks/LiteRT-LM/upstream/runtime/components/top_k_metal_sampler.h` — include path normalization + compat aliases
- `Forks/LiteRT-LM/upstream/runtime/components/top_k_metal_sampler.mm` — include path normalization + 3 easy API patches
- `Forks/LiteRT-LM/upstream/runtime/components/BUILD` — added `top_k_gpu_sampler` and `top_k_metal_sampler` targets

## Spike Verdict

The Metal sampler spike is **closed as no-go**.

The two remaining build errors on `InitFromGpuModel` are not patchable without
reimplementing the internal GPU graph construction and top-k kernel that the OSS
tree omits.
