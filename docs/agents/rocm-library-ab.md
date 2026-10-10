# ComfyUI's idle CPU spin, and the A/B of a ROCm library

How to measure whether a process that holds the GPU spins a CPU core while idle, and how to test another build of a ROCm library in ComfyUI's pod without changing the Lab. ADRs [0011](../adr/0011-comfyui-runs-a-fixed-rocprofiler-sdk.md) and [0012](../adr/0012-comfyui-runs-rocr-with-upstreams-event-age-fix.md) record the two spins this found. A `rocm/pytorch` tag with another ROCm needs it again.

Everything runs in ComfyUI's container, with the GPU Node Joined:

```bash
kubectl --context k3d-lab -n comfyui exec -it ds/comfyui -c comfyui -- bash
```

## Measuring the spin

A thread's CPU time is fields 14 and 15 of `/proc/<pid>/task/<tid>/stat`, in ticks of 1/100 s, so over 10 s one core is 1000 ticks. Paste these into the pod's shell:

```bash
snap() { local t; for t in /proc/$1/task/*; do echo "${t##*/} $(tr ' ' _ <$t/comm) $(sed 's/.*) //' $t/stat | cut -d' ' -f12,13)"; done; }
# <pid>: the total over 10 s, then the ticks of each thread that used any.
ticks() { { snap $1; sleep 10; snap $1; } | awk '
  { seen[$1]++; d[$1] = $3 + $4 - d[$1]; name[$1] = $2 }
  END { for (t in d) if (seen[t] == 2) { sum += d[t]; if (d[t]) print d[t], t, name[t] }; print sum + 0, "total" }' | sort -rn; }
```

- **Measure twice: after a GPU init, and after a job.** rocprofiler-sdk's spin (ADR 0011) starts at the first GPU use, so a bare `torch.zeros(1, device="cuda")` followed by a `time.sleep` shows it. ROCr's (ADR 0012) starts only after ComfyUI's first job, with dynamic VRAM and async offload on: a process that read 0 after the init read 998 after the job.
- **Wait for the job to finish** before sampling, or the ticks are the job's.
- **The GPU init on its own,** which needs no ComfyUI:

  ```bash
  /models/comfyui/runtime/venv/bin/python -c 'import time, torch; torch.zeros(1, device="cuda"); time.sleep(600)' & p=$!
  sleep 30; ticks $p; kill $p
  ```
- **A spin is one thread near 1000** and every other thread at 0: ROCr's `AsyncEventsLoop`, which shows under the process's own name, `python`. An idle process totals 0 or 1.
- **The Lab's own ComfyUI is PID 1** in the container: `ticks 1`.

## A/B of a library

ArgoCD puts back a changed DaemonSet unless ComfyUI is Paused, and every change to it restarts the pod. So the test changes nothing in the Lab: it's a second ComfyUI in the same pod, which finds ROCm through a shadow of the `_rocm_sdk_core` package in `/work`. PyTorch locates ROCm's libraries by that package's import path, and `PYTHONPATH` comes before the image's site-packages. Only that package needs a shadow, not all of site-packages: ComfyUI's own packages stay as they are. The shadow's entries are symlinks to the image's, except `lib/`, a real directory of symlinks where the library under test is a file of its own:

```bash
sp=/opt/venv/lib/python3.12/site-packages
# <name> [<library>...]: the shadow /work/ab/<name>, with those libraries in place of the pod's.
shadow() {
  local d=/work/ab/$1/_rocm_sdk_core e; shift
  rm -rf $d; mkdir -p $d/lib
  for e in $sp/_rocm_sdk_core/*; do [[ ${e##*/} == lib ]] || ln -s $e $d/; done
  ln -s $sp/_rocm_sdk_core/lib/* $d/lib/
  for e in "$@"; do cp --remove-destination $e $d/lib/; done
}
```

- **Don't use `LD_PRELOAD`.** It maps the image's copy as well, and that alone hides the spin: the unpatched control read 0 too (ADR 0011).
- **Always run a control:** `shadow control`, with no library swapped, run and measured exactly like the variant. Without it, a 0 may come from the setup rather than from the library.
- **Check that one copy is mapped,** and that it's the one meant:

  ```bash
  grep -o '/[^ ]*lib\(hsa-runtime64\|rocprofiler-sdk\)\.so[^ ]*' /proc/<pid>/maps | sort -u
  ```

  One line per library: the file in `/work/ab/<name>/` for a swapped one, the one in `/opt/venv` otherwise. For another library, change the pattern.
- **A library must keep the image's RPATH,** which finds its dependencies relative to its own directory. The Lab's builds set it with `patchelf`; see the workflows on the `lab/*` branches of `StefanBS/rocm-systems`.

### The image's own libraries

In the Lab's pod, `librocprofiler-sdk.so.1` and `libhsa-runtime64.so.1` in `/opt/venv` are the fixed builds, mounted over the image's, which the pod can't reach. So the control there is the fixed pair, and the image's are the variant: its ROCr with the fixed rocprofiler-sdk spins after a job, and its rocprofiler-sdk spins from the GPU init. They come from AMD's wheel for the image's ROCm, which ComfyUI's Workload policy doesn't allow, so fetch it on the Host (415 MB), in a temporary directory, and copy the library in:

```bash
lib=libhsa-runtime64.so.1    # or librocprofiler-sdk.so.1
cd "$(mktemp -d)"
curl -fsSLO https://repo.amd.com/rocm/whl-multi-arch/rocm_sdk_core-7.14.1-py3-none-linux_x86_64.whl
unzip rocm_sdk_core-7.14.1-py3-none-linux_x86_64.whl "_rocm_sdk_core/lib/$lib"
kubectl --context k3d-lab -n comfyui exec -i ds/comfyui -c comfyui -- \
  sh -c "mkdir -p /work/ab/image && cat > /work/ab/image/$lib" < "_rocm_sdk_core/lib/$lib"
```

The image's package records the checksum of each file it installed, so check in the pod that the copy is the image's, which prints 1:

```bash
f=/work/ab/image/libhsa-runtime64.so.1    # or librocprofiler-sdk.so.1
sp=/opt/venv/lib/python3.12/site-packages
grep -c "${f##*/},sha256=$(python -c 'import base64, hashlib, sys
print(base64.urlsafe_b64encode(hashlib.sha256(open(sys.argv[1], "rb").read()).digest()).decode().rstrip("="))' $f)," \
  $sp/rocm_sdk_core-*.dist-info/RECORD
```

### One run

For each of the control and the variant, in a pod whose own ComfyUI has run no job yet: both share the container's 24 GiB, and the GPU's VRAM.

```bash
shadow rocr-image /work/ab/image/libhsa-runtime64.so.1    # or: shadow control
n=rocr-image
mkdir -p /work/ab/$n/{user,output,input,temp}
cd /models/comfyui/runtime
PYTHONPATH=/work/ab/$n venv/bin/python ComfyUI/main.py --listen 127.0.0.1 --port 8189 \
  --extra-model-paths-config /config/extra_model_paths.yaml \
  --user-directory /work/ab/$n/user --output-directory /work/ab/$n/output \
  --input-directory /work/ab/$n/input --temp-directory /work/ab/$n/temp --reserve-vram 3
```

From a second shell in the pod, with `ticks` defined, once the first prints that it's listening:

```bash
pid=$(pgrep -f '^venv/bin/python .*--port 8189')
grep -o '/[^ ]*lib\(hsa-runtime64\|rocprofiler-sdk\)\.so[^ ]*' /proc/$pid/maps | sort -u
ticks $pid                                    # idle before the job
curl -fsS -H 'Content-Type: application/json' -d "{\"prompt\": $(cat /work/ab/job.json)}" http://127.0.0.1:8189/prompt
until curl -fsS http://127.0.0.1:8189/queue | python -c 'import json, sys
q = json.load(sys.stdin); sys.exit(bool(q["queue_running"] or q["queue_pending"]))'; do sleep 5; done
ticks $pid                                    # idle after the job
pkill -f '^venv/bin/python .*--port 8189'
```

- **For the GPU init alone,** run the `python -c` line above with the same `PYTHONPATH=/work/ab/$n` instead of ComfyUI.
- **`job.json` is a workflow in API format,** exported from https://comfyui.lab.localhost and copied in like the library. Every image ComfyUI saved carries its own, as the `prompt` text chunk of the PNG: `json.loads(PIL.Image.open(<png>).info["prompt"])`. Both measurements below used a Qwen-Image-2.1 text to image job at 512×512 and 20 steps, which takes 23 s.
- **Anchor the `pgrep -f` pattern at ComfyUI's command line.** Run through `kubectl exec ... -- bash -c '<script>'`, a looser pattern such as `[p]ort 8189` also matches the `bash` that holds the script, since the script names the port. `ticks` then samples that `bash`, which reads 0 whatever the library, and `pkill` ends the script.
- **`/work` is the pod's emptyDir,** so a restart of the pod removes every shadow.

## What it measured

Ticks over 10 s. On 2026-10-10, following this page in the Lab's pod, with the other library the Lab's fixed build in each row:

| Variant | After the GPU init | Idle before the job | Idle after it |
|---|---|---|---|
| Control: both fixed builds | 0 | 0 | 0 |
| The image's `librocprofiler-sdk.so.1` | 1005 | | |
| The image's `libhsa-runtime64.so.1` | | 0 | 1016 |
| Control again | | 0 | 0 |

The spin was still at 1016 30 s after the job. For #106, with the fixed rocprofiler-sdk in every row:

| `libhsa-runtime64.so.1` | Idle before the job | Idle after it |
|---|---|---|
| The image's | 0 | 998 |
| 7.14.1 built like the Lab's, without the fix | 0 | 999 |
| The Lab's fixed build | 0 | 0 |

The row in the middle is what tells the fix from the build: a library built from the same commit, the same way, without the patch.
