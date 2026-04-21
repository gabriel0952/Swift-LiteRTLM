# LiteRT Fork Plan

Last updated: 2026-04-20

## Purpose

This document defines the fork strategy for expanding this repository beyond the Swift Package wrapper into a multi-repo workspace that can investigate and, if feasible, close the current iOS GPU runtime gap.

The goal is not to assume GPU success up front. The goal is to:

- keep the root Swift Package stable and usable
- isolate upstream fork work into dedicated workspaces
- prove or disprove the public OSS path for iOS GPU support with bounded spikes

## Current Problem Statement

The current public upstream path is incomplete for iOS GPU:

- `LiteRT-LM` exposes GPU-related hooks and includes Metal sampler source, but the public BUILD graph does not expose a complete iOS GPU path
- `LiteRT` exposes a GPU registry that attempts to load accelerator dylibs such as `libLiteRtMetalAccelerator.dylib`
- the corresponding public iOS accelerator packaging path is not complete in the current OSS tree and prebuilt delivery flow

Because of that, the Swift API can request `.gpu`, but a third-party iOS app cannot currently rely on the public upstream artifacts to satisfy that request.

## Repository Roles

The workspace is split into three layers:

- Repository root
  - role: shipping Swift Package wrapper
  - key paths: `Package.swift`, `Sources/`, `Tests/`, `Frameworks/`
- `Forks/LiteRT-LM/`
  - role: runtime, sampler, and XCFramework build experiments
- `Forks/LiteRT/`
  - role: GPU accelerator, runtime packaging, and prebuilt gap investigation

Supporting paths:

- `Apps/test-app/`
  - local validation app for integration testing against the root package
- `Docs/Plans/`
  - plans, research notes, and spike outcomes

## Success Criteria

The fork effort is considered successful only if all of the following become true:

- an iOS app can request `GPU` without runtime dylib load failure
- the required GPU artifacts are produced by a reproducible build path
- the result can be packaged back into `Frameworks/LiteRTLM.xcframework`
- the local validation app can initialize and run inference using the GPU path

If those conditions are not met, the workspace should remain CPU-first and document the GPU path as blocked upstream.

## Non-Goals

- rewriting the Swift Package public API
- destabilizing the current CPU path
- mixing experimental upstream fork code into the root package prematurely
- committing to long-term GPU runtime maintenance before the public source gap is understood

## Execution Strategy

### Phase 0: Stable Baseline

Objective:

- keep the root Swift Package buildable and usable while fork work starts

Deliverables:

- stable root package layout
- local validation app in `Apps/test-app/`
- documented iOS GPU limitation in `README.md`

Exit criteria:

- package builds
- local app resolves the package from the new workspace layout
- CPU path remains the default reliable path

### Phase 1: LiteRT-LM Sampler Spike

Objective:

- determine whether the public LiteRT-LM source is sufficient to build the Metal sampler path independently

Scope:

- work only inside `Forks/LiteRT-LM/`
- do not modify the root package API during the spike

Primary tasks:

- add the missing `TopKGpuSampler` abstraction if it is not present in OSS
- wire `top_k_metal_sampler.mm` into the public BUILD graph
- attempt to build a standalone `libLiteRtTopKMetalSampler.dylib`
- confirm whether `sampler_factory.cc` can dynamically resolve the sampler symbols

Expected outputs:

- a minimal BUILD target for the Metal sampler
- notes on missing symbols, missing headers, and missing dependencies
- a clear pass/fail result for sampler-only viability

Exit criteria:

- success: standalone sampler dylib builds and exports the expected C API
- fail: the sampler depends on too many missing internal-only pieces to be a practical fork target

Stop condition:

- if this phase spends multiple days reconstructing missing internal scaffolding without producing a dylib, stop and record the gap

### Phase 2: LiteRT Accelerator Recon

Objective:

- determine whether the real iOS GPU accelerator can be built from public LiteRT source

Scope:

- work inside `Forks/LiteRT/`
- focus on source availability first, not packaging polish

Primary tasks:

- trace all references to `ml_drift_metal_accelerator` and related GPU targets
- compare public BUILD files with commented `copybara` references
- verify whether `runtime/accelerators/gpu` is absent from OSS or merely unhooked
- inspect the public prebuilt delivery path and expected artifact names

Expected outputs:

- a source-gap report
- a target-availability report
- a go / no-go decision on manual accelerator implementation

Exit criteria:

- success: enough public source exists to define a plausible iOS Metal accelerator target
- fail: the accelerator source is materially absent from OSS and would require full reimplementation

### Phase 3: Minimal GPU PoC

Prerequisite:

- proceed only if Phase 2 shows that a real accelerator path is technically buildable

Objective:

- produce the smallest end-to-end iOS GPU proof of concept

Primary tasks:

- build the required accelerator dylib(s)
- package them into the XCFramework build flow
- make the root package detect and use the produced runtime artifacts
- verify initialization and a minimal inference pass from `Apps/test-app/`

Expected outputs:

- reproducible build steps for GPU runtime artifacts
- packaged XCFramework containing the required runtime dylibs
- local app evidence that the GPU path initializes successfully

Exit criteria:

- `Apps/test-app/` can initialize using `GPU`
- runtime no longer fails with missing accelerator dylib errors

### Phase 4: Productization

Objective:

- decide whether the PoC should become a supported maintained path

Primary tasks:

- reduce and document the fork diff
- define update strategy for both forks
- add CI or scripted verification for the GPU packaging path
- document rollback behavior and supported platforms

Decision gate:

- only continue if the cost of maintaining the forked runtime path is justified by product needs

## Risk Assessment

### High Risk

- the real iOS Metal accelerator source may not be fully present in public OSS
- `LiteRT-LM` may reference internal-only GPU abstractions not included in the public tree
- a working PoC may still depend on fragile manual packaging steps

### Medium Risk

- upstream repo layout or prebuilt behavior may shift while the fork is in progress
- Xcode, Bazel, and Flutter integration can introduce build-system churn unrelated to the runtime itself

### Lower Risk

- root package and local app workspace organization
- CPU validation path

## Go / No-Go Rules

Continue only if:

- Phase 1 can produce a meaningful sampler result
- Phase 2 confirms that a real accelerator path is technically reconstructable

Stop and remain CPU-first if:

- the accelerator path requires substantial source reimplementation
- the fork becomes a runtime rewrite rather than a targeted packaging / build recovery
- maintenance cost exceeds the value of adopting a different Metal-capable backend

## Immediate Next Actions

1. Keep the root package stable and CPU-first.
2. Record all GPU runtime findings in `Docs/Plans/`.
3. Start with the LiteRT-LM sampler spike before attempting a full LiteRT accelerator implementation.
4. Treat `Forks/LiteRT/` as a source-gap investigation until proven otherwise.

## Deliverables Checklist

- [ ] Phase 1 spike notes and result
- [ ] Phase 2 source-gap report
- [ ] go / no-go decision memo
- [ ] minimal GPU PoC, if feasible
- [ ] maintained packaging path, only if PoC succeeds
