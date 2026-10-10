# ComfyUI runs ROCr with upstream's event-age fix until ROCm ships it

With the fixed rocprofiler-sdk (ADR 0011), ComfyUI is idle at start, but after its first job one CPU core goes back to 100% while dynamic VRAM and async offload are both on, its defaults.

- **The cause is in ROCr's `AsyncEventsLoop`.** Each AQL queue has two signals with async handlers that share one KFD event, so the loop's list of events to wait on holds duplicates. ROCm 7.14.1 drops them with `std::unique`, which compacts the events but not their ages, and resets an age to 1 whenever a slot's event changes. KFD then reports every event that has fired since as ready, the wait returns at once, and the loop spins: about 4000 waits a second, measured with ptrace.
- **Upstream fixed it on `develop`** (`c06ea68a59` and three follow-ups, which key the ages by event), after ROCm 7.14 branched. The branch `lab/rocr-runtime-7.14.1-event-age` of `StefanBS/rocm-systems` is ROCm 7.14.1's commit (`ca887ee80abf`) plus those four commits, and builds `libhsa-runtime64.so.1` the way ADR 0011's branch builds rocprofiler-sdk. Setup downloads it, pinned by checksum, and the DaemonSet mounts it over the image's copy.
- **Measured in the pod**, a second ComfyUI with each library and one Qwen-Image job: the image's ROCr and the same build without the fix spin after the job, this one stays at 0. [The how-to](../agents/rocm-library-ab.md) has the procedure.

## Considered Options

- **Turning off dynamic VRAM or async offload**: either stops the spin, at the cost of a ComfyUI feature, and leaves the bug in place for anything else.
- **The same options as ADR 0011**, rejected for the same reasons.

## Consequences

- **The library is tied to ROCm 7.14.1**, like ADR 0011's. A ROCm that has upstream's fix makes this mount unnecessary.
- **ROCr is the runtime every GPU call goes through**, so a bad build breaks ComfyUI outright rather than just its idle CPU.
