# ComfyUI runs a fixed rocprofiler-sdk until ROCm ships one

Every process that uses the GPU through the image's PyTorch keeps one CPU core at 100% for as long as it runs, even with the GPU idle. On the GPU Node that holds the Ryzen at full boost, and the fans with it.

- **The cause is rocprofiler-sdk**, which `libtorch_cpu.so` links. At the first GPU use it creates a pool of 4096 HSA interrupt signals, each holding one KFD event, and KFD allows 4096 per process. Signals created after that get no event, among them a queue's ready signal, which has an async handler, so ROCr's `AsyncEventsLoop` polls instead of sleeping.
- **The fix creates the pool in batches of 1024**, and is on the branch `lab/rocprofiler-sdk-7.14.1-signal-pool` of `StefanBS/rocm-systems`: ROCm 7.14.1's own commit (`ca887ee80abf`) plus the fix. A workflow there builds `librocprofiler-sdk.so.1` against the ROCm 7.14.1 wheels and attaches it to a release. ComfyUI's setup step downloads it to the GPU Node, pinned by checksum, and the DaemonSet mounts it over the image's copy.
- **Upstream's ROCm/rocm-systems#7898 only throttles the polling**, and isn't in any released ROCm.

## Considered Options

- **An image of the Lab's with the library swapped in**: what ADR 0007 rules out, for the same reason; the image is 19.6 GB.
- **`LD_PRELOAD` of the fixed library**: maps the image's copy as well, and that alone hides the spin, so it can't be told apart from the fix working.
- **Building the library on the GPU Node** in the setup step: about 10 minutes per build, and it needs packages the non-root setup container can't install.

## Consequences

- **The library is tied to ROCm 7.14.1.** A `rocm/pytorch` tag with another ROCm needs a new build from that ROCm's commit, or this mount removed if that ROCm has the fix.
- **It doesn't stop a second spin**, which starts after ComfyUI's first job while dynamic VRAM and async offload are both on. That one is in ROCr, which ADR 0012 replaces the same way.
