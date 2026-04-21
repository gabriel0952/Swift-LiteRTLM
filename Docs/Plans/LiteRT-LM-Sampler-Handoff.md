# LiteRT-LM Sampler Handoff

Last updated: 2026-04-20 (spike closed)

## Purpose

This document is the direct handoff note for the next agent continuing the
LiteRT-LM / LiteRT fork investigation.

Use this file first if the goal is to continue the Metal sampler spike without
repeating the earlier source-gap analysis.

## Current Status — SPIKE CLOSED (no-go)

The spike has reached its stop conditions. No further investigation is needed.

The full no-go decision record is in:

- `Docs/Plans/LiteRT-LM-Sampler-No-Go.md`

Summary of what is now known:

- the public LiteRT-LM OSS tree does contain `top_k_metal_sampler.h/.mm`
- the public BUILD graph does not expose that sampler by default
- the missing `TopKGpuSampler` abstraction can be reconstructed enough for the
  public workspace to compile a minimal scaffold target
- three easy API patches were applied to reduce the error set from 6 to 4
- the two remaining hard blockers (`InferenceContext::InitFromGpuModel` at two
  call sites) are not patchable without reimplementing the top-k GPU algorithm
- both stop conditions from the spike plan are met

## What Was Done

### 1. Workspace preparation

Upstream checkouts already exist locally:

- `Forks/LiteRT-LM/upstream`
- `Forks/LiteRT/upstream`

Observed revisions during this spike:

- `LiteRT-LM`: `e5aa333`
- `LiteRT`: `45dd41f`

### 2. Minimal GPU sampler scaffold added

The following file was added in the LiteRT-LM fork:

- `Forks/LiteRT-LM/upstream/runtime/components/top_k_gpu_sampler.h`

This file reconstructs a minimal public-compatible scaffold for:

- `TransformerConfig`
- `LlmRuntimeParams`
- `TopKGpuSampler`
- helper methods used by `TopKMetalSampler`

It is intentionally minimal and only exists to push the spike forward to the
next real failure point.

### 3. BUILD targets added

The following targets were added to:

- `Forks/LiteRT-LM/upstream/runtime/components/BUILD`

New targets:

- `//runtime/components:top_k_gpu_sampler`
- `//runtime/components:top_k_metal_sampler`

### 4. Metal sampler source normalized to public include paths

These files were modified:

- `Forks/LiteRT-LM/upstream/runtime/components/top_k_metal_sampler.h`
- `Forks/LiteRT-LM/upstream/runtime/components/top_k_metal_sampler.mm`

Changes made:

- removed dependency on internal `third_party/ml_drift/...` include paths
- switched to public TensorFlow GPU Metal headers
- added minimal namespace compatibility aliases to keep the fork moving

## Verified Commands And Results

Run from:

- `Forks/LiteRT-LM/upstream`

### Successful

Command:

```sh
bazelisk build //runtime/components:top_k_gpu_sampler
```

Result:

- succeeded

Meaning:

- the minimal `TopKGpuSampler` scaffold is valid enough for the public Bazel
  workspace

### Current failing build

Command:

```sh
bazelisk build //runtime/components:top_k_metal_sampler
```

Result:

- fails in `runtime/components/top_k_metal_sampler.mm`

Current failure set:

- `ComputeTask::Init(...)` signature mismatch
- `GPUOperation` has no `code_info_`
- `ModelHints::kPreferTextureWeights` missing
- `InferenceContext::InitFromGpuModel(...)` missing
- `ComputeTask::SetInt(...)` missing
- `ComputeTask::SetFloat(...)` missing

## Files Changed In This Spike

Primary fork files:

- `Forks/LiteRT-LM/upstream/runtime/components/top_k_gpu_sampler.h`
- `Forks/LiteRT-LM/upstream/runtime/components/top_k_metal_sampler.h`
- `Forks/LiteRT-LM/upstream/runtime/components/top_k_metal_sampler.mm`
- `Forks/LiteRT-LM/upstream/runtime/components/BUILD`

Documentation files:

- `Docs/Plans/LiteRT-LM-Sampler-Spike-Log.md`
- `Docs/Plans/LiteRT-LM-Sampler-Handoff.md`

## What The Current Evidence Means

The problem has narrowed from:

- "public OSS is missing files"

to:

- "the OSS Metal sampler source appears to have been written against a richer
  internal `ml_drift` API surface than the public TensorFlow Metal runtime now
  exposes"

This is important because the next step is no longer simple BUILD repair.

The next step requires deciding whether to:

- adapt `top_k_metal_sampler.mm` to public TensorFlow Metal APIs
- or stop the spike if that adaptation becomes equivalent to rewriting the
  sampler implementation

## Recommended Next Steps

Priority order:

1. Compare each failing API call against the public TensorFlow Metal runtime and
   classify it as either:
   - easy compatibility patch
   - medium adapter work
   - hard internal-only behavior
2. Start with the easiest compatibility fixes first:
   - change `ComputeTask::Init(std::move(gpu_op), false)` to the public
     `Init(std::move(gpu_op))`
   - replace `GPUOperation::code_info_.uses_global_id` with the current public
     API equivalent if one exists, otherwise remove it and observe the next
     behavior
   - replace or drop `ModelHints::kPreferTextureWeights`
3. Investigate the two highest-risk gaps before doing large edits:
   - how public Metal `InferenceContext` should be initialized instead of
     `InitFromGpuModel(...)`
   - how to set scalar params now that `ComputeTask` no longer exposes
     `SetInt` / `SetFloat`
4. If the public API requires rebuilding the sampler's execution model rather
   than adapting a few calls, stop the spike and record that the Metal sampler
   path is effectively internal-only

## High-Risk Areas To Check Next

### A. InferenceContext initialization

The OSS sampler currently assumes:

- `InferenceContext::InitFromGpuModel(...)`

Public Metal `InferenceContext` instead exposes graph-based initialization APIs.

This may require:

- constructing a real `GraphFloat32`
- or using a different model conversion path

If that is required, this spike may already be approaching "runtime rewrite"
rather than "build recovery".

### B. Scalar parameter injection

The sampler currently assumes:

- `ComputeTask::SetInt(...)`
- `ComputeTask::SetFloat(...)`

The public Metal API appears to keep these setters inside `metal_args_`, not on
`ComputeTask` itself.

This means the next agent should check whether:

- a public forwarding API exists elsewhere
- or the sampler must be reworked to build params into the `GPUOperation`
  argument map differently

### C. GPUOperation metadata

The removed `code_info_` field suggests the OSS sampler source is using an older
or internal `GPUOperation` shape.

Check whether the public `GPUOperation` now infers the same behavior from other
state, or whether the generated kernel code must be adjusted.

## Stop Conditions

Stop this spike and document a no-go decision if any of the following becomes
true:

- `InferenceContext` adaptation requires rebuilding internal graph-construction
  logic not present in OSS
- scalar param updates require intrusive rewrites across the sampler path
- the Metal sampler can only be made to compile by reimplementing substantial
  portions of internal `ml_drift`

If that happens, the right next document is not more patching. The right next
document is a clear no-go memo saying:

- the public LiteRT-LM Metal sampler source is not practically recoverable
  against the public TensorFlow Metal runtime

## Commands Likely Needed Next

From `Forks/LiteRT-LM/upstream`:

```sh
bazelisk build //runtime/components:top_k_metal_sampler
```

Useful source inspection targets:

```sh
sed -n '1,240p' runtime/components/top_k_metal_sampler.mm
sed -n '1,220p' runtime/components/top_k_metal_sampler.h
sed -n '1,220p' runtime/components/top_k_gpu_sampler.h
```

Public TensorFlow Metal API files already proven relevant:

- `external/org_tensorflow/tensorflow/lite/delegates/gpu/metal/compute_task.h`
- `external/org_tensorflow/tensorflow/lite/delegates/gpu/metal/inference_context.h`
- `external/org_tensorflow/tensorflow/lite/delegates/gpu/metal/metal_spatial_tensor.h`
- `external/org_tensorflow/tensorflow/lite/delegates/gpu/common/task/gpu_operation.h`
- `external/org_tensorflow/tensorflow/lite/delegates/gpu/common/model_hints.h`

## Notes For The Next Agent

- Do not spend time rediscovering whether the target can be added to BUILD.
  That part is already done.
- Do not spend time rediscovering whether `TopKGpuSampler` is missing. That is
  already confirmed and partially reconstructed.
- The open question is now strictly about whether the OSS Metal sampler can be
  adapted to the public TensorFlow Metal runtime without turning into a runtime
  rewrite.
