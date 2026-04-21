# LiteRT-LM Sampler Spike Log

Last updated: 2026-04-20

## Scope

This document records the first execution pass of the LiteRT-LM sampler spike from the fork plan.

Primary objective:

- determine whether the public LiteRT-LM OSS tree contains enough source to build the Metal top-k sampler path

## Workspace Bootstrap

Local upstream checkouts created under:

- `Forks/LiteRT-LM/upstream`
- `Forks/LiteRT/upstream`

Observed upstream revisions during this pass:

- `LiteRT-LM`: `e5aa333`
- `LiteRT`: `45dd41f`

## Confirmed Findings

### 1. The Metal sampler source exists

Public LiteRT-LM contains:

- `runtime/components/top_k_metal_sampler.h`
- `runtime/components/top_k_metal_sampler.mm`

This confirms the Metal sampler path is not purely hypothetical. There is real source in the OSS tree.

### 2. The public BUILD graph does not expose the Metal sampler

`runtime/components/BUILD` contains:

- `default_static_gpu_samplers`

But that target is empty in the public tree.

There is currently no public target in `runtime/components/BUILD` that builds:

- `top_k_metal_sampler.mm`
- `libLiteRtTopKMetalSampler.dylib`

### 3. The sampler depends on a missing base abstraction

`top_k_metal_sampler.h` includes:

- `runtime/components/top_k_gpu_sampler.h`

That file is not present in the public OSS tree.

This is the first hard blocker to compiling the sampler path.

### 4. The missing base is not trivial

`TopKMetalSampler` does not only inherit from `TopKGpuSampler`; it also relies on inherited shared state and helper methods, including names referenced from the `.mm` file such as:

- `create_info_`
- `sampler_params_`
- `rand_gen_`
- `config_`
- `Initialize()`
- `GetTokensTensorDescriptor()`
- `GetParamsTensorDescriptor()`
- `CreateSamplingModel(...)`
- `CreateInputHandlingModel(...)`
- `CreateLlmRuntimeParams(...)`
- `CreateFloatParams(...)`
- `LlmRuntimeParams`
- `TransformerConfig`

This means the missing abstraction is not just a header declaration. It likely includes shared top-k GPU sampler logic that has been omitted from OSS.

### 5. The factory path is ready for a dylib if one can be built

`runtime/components/sampler_factory.cc` already contains dynamic and static loading logic for:

- `libLiteRtTopKMetalSampler.dylib`
- `LiteRtTopKMetalSampler_Create`
- `LiteRtTopKMetalSampler_Destroy`
- `LiteRtTopKMetalSampler_SampleToIdAndScoreBuffer`
- `LiteRtTopKMetalSampler_UpdateConfig`
- `LiteRtTopKMetalSampler_CanHandleInput`
- `LiteRtTopKMetalSampler_HandlesInput`
- `LiteRtTopKMetalSampler_SetInputTensorsAndInferenceFunc`

This is important: the consumer side exists. The missing part is the buildable implementation path.

### 6. LiteRT still lacks the public GPU accelerator package

In the parallel LiteRT fork bootstrap, the public tree still exposes only:

- `runtime/accelerators`
- `runtime/accelerators/dispatch`
- `runtime/accelerators/xnnpack`

There is still no public `runtime/accelerators/gpu` directory in the OSS tree.

This keeps the overall iOS GPU path high risk even if the sampler spike eventually succeeds.

## Current Assessment

The sampler spike is still worth continuing, but expectations should be narrow:

- best-case outcome: reconstruct enough shared top-k GPU sampler scaffolding to build `libLiteRtTopKMetalSampler.dylib`
- worst-case outcome: prove that the shared top-k GPU layer is internal-only and not practical to reconstruct cleanly

At this point, the sampler spike is not blocked by uncertainty anymore. It is blocked by a concrete missing abstraction layer.

## Second Pass Progress

### 7. A minimal `TopKGpuSampler` scaffold can be integrated into the public workspace

The fork now includes a minimal `runtime/components/top_k_gpu_sampler.h` plus a
new `//runtime/components:top_k_gpu_sampler` target in the LiteRT-LM fork.

Verification result:

- `bazelisk build //runtime/components:top_k_gpu_sampler`
- result: `BUILD COMPLETED SUCCESSFULLY`

This matters because it proves the missing base abstraction is reconstructable
enough for Bazel analysis and compilation to continue.

### 8. The public include path can be normalized, but the public Metal API still diverges

The Metal sampler source was also wired into a new public target:

- `//runtime/components:top_k_metal_sampler`

To make that target buildable in OSS, the fork switched `top_k_metal_sampler.h`
and `top_k_metal_sampler.mm` away from the internal `third_party/ml_drift/...`
include paths toward public TensorFlow GPU Metal headers.

That got the build past the missing-header failure and exposed the next layer of
real incompatibilities.

### 9. The next blocker is API drift between the sampler source and public TensorFlow Metal classes

Current `bazelisk build //runtime/components:top_k_metal_sampler` now fails with
concrete API mismatches against public TensorFlow GPU Metal:

- `ComputeTask::Init(...)` signature mismatch
  - sampler expects `Init(operation, use_argument_buffer)`
  - public API only exposes `Init(operation)`
- `GPUOperation` no longer exposes `code_info_`
- `ModelHints::kPreferTextureWeights` is not present in the public API
- `InferenceContext::InitFromGpuModel(...)` does not exist in the public API
- `ComputeTask::SetInt(...)` does not exist in the public API
- `ComputeTask::SetFloat(...)` does not exist in the public API

This is an important narrowing step:

- the fork is no longer blocked on missing files
- it is now blocked on behavioral/API divergence between the public TensorFlow
  Metal runtime and the `top_k_metal_sampler.mm` implementation

### 10. Revised assessment after the second pass

The spike is still useful, but the problem has changed shape:

- first blocker: missing `TopKGpuSampler` base
- second blocker: internal/public TensorFlow GPU Metal API drift

This strongly suggests the OSS Metal sampler source was authored against a more
capable internal `ml_drift` surface than the public TensorFlow Metal runtime now
provides.

## Third Pass Progress (2026-04-20)

### 11. Three easy API patches applied

Before confirming the stop conditions, three easy compilation fixes were applied
to `top_k_metal_sampler.mm`:

- `ComputeTask::Init(op, false)` → `Init(op)` — public API dropped the second arg
- `op.code_info_.uses_global_id = true` — removed, field does not exist in public GPUOperation
- `create_info.hints.Add(ml_drift::ModelHints::kPreferTextureWeights)` — removed, hint not in public API

### 12. Build confirmed: 6 errors → 4 errors after easy fixes

After the three patches the error set reduced from 6 to 4:

- `InferenceContext::InitFromGpuModel` (line 321) — no public API
- `ComputeTask::SetInt` (line 348) — no public API on ComputeTask
- `ComputeTask::SetFloat` (line 364) — no public API on ComputeTask
- `InferenceContext::InitFromGpuModel` (line 545) — no public API (second call site)

### 13. Stop conditions confirmed — spike closed as no-go

**`InferenceContext::InitFromGpuModel`** is a hard stop:

- The public `InferenceContext` only exposes `InitFromGraph(GraphFloat32)` and
  `InitFromGraphWithTransforms(GraphFloat32*)`
- Adapting to the public path requires expressing the top-k sampling algorithm
  as a `GraphFloat32` with TFLite GPU delegate operators
- The actual top-k GPU kernel is not in OSS (it is in internal `ml_drift`)
- This is equivalent to reimplementing the Metal sampler from scratch

**`ComputeTask::SetInt`/`SetFloat`** is medium complexity in isolation:

- `SetInt`/`SetFloat` exist on `MetalArguments` (private member of `ComputeTask`)
- A workaround exists: create params buffers with `MTLResourceStorageModeShared`
  and write scalars from CPU via `memcpy`
- This workaround is moot because `InitFromGpuModel` is the fatal blocker

See `Docs/Plans/LiteRT-LM-Sampler-No-Go.md` for the full no-go decision record.

## First Implementation Target

The first implementation target for the next pass is:

- reconstruct a minimal public-compatible `top_k_gpu_sampler.h/.cc` in the LiteRT-LM fork workspace

That reconstruction should only aim to satisfy what `TopKMetalSampler` actually uses.

## Minimal Interface To Reconstruct

The next pass should verify and, if feasible, reconstruct:

- `TransformerConfig`
- `LlmRuntimeParams`
- `TopKGpuSampler`
- `TopKGpuSampler::Initialize()`
- `TopKGpuSampler::GetTokensTensorDescriptor()`
- `TopKGpuSampler::GetParamsTensorDescriptor()`
- `TopKGpuSampler::CreateSamplingModel(...)`
- `TopKGpuSampler::CreateInputHandlingModel(...)`
- `CreateLlmRuntimeParams(...)`
- `CreateFloatParams(...)`

## Stop Rule

Stop the sampler spike if reconstructing the above requires:

- large portions of missing internal ml_drift integration logic
- substantial algorithm reimplementation rather than build-graph recovery
- speculative recreation without enough behavioral anchors from the public tree

If that happens, record the sampler path as effectively internal-only and return focus to the higher-level fork decision.
