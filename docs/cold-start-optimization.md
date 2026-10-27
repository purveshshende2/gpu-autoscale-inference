# Cold Start Optimization: Research, Plan and Results

**Status:** Implemented and benchmarked on GCP GKE T4 Spot (us-east1-d).
**Result:** Cold start reduced from **about 11 min** to **about 5.6 min** end-to-end.

## Problem

vLLM on GKE with scale-to-zero GPU nodes had an ~11 minute cold start:

```
2.5m: Cluster Autoscaler provisions GPU VM (n1-standard-4 + T4 Spot)
6.5m: GPU node pulls 11GB Docker image from Artifact Registry (~28MB/s)
2m:   vLLM starts Python/CUDA and loads model weights into VRAM
----
~11m total from queue spike to first token
```

The 28MB/s pull speed is not network-bandwidth-limited (n1-standard-4 has 10Gbps).
It is limited by containerd's default layer-pull parallelism (3 concurrent layers)
and CPU decompression on a 4-vCPU node. No GKE config knob exposes
`max_concurrent_downloads`.

## Why the Image Is 11GB (Baseline)

The original custom vLLM image baked the Qwen2.5-1.5B model weights into the image:

```
vllm/vllm-openai base:   ~8GB  (PyTorch + CUDA + vLLM)
Qwen2.5-1.5B weights:    ~3.5GB (baked in via snapshot_download)
--------------------------------
Total:                   ~11GB
```

This was intended to eliminate the 29s HuggingFace download at runtime. It was the
wrong tradeoff: adding 3.5GB to the pull cost (extra ~1.5 min) to save 29s. Net
effect: cold start got slower.

## Approaches Evaluated

| Approach | Works for scale-to-zero? | Expected savings | Verdict |
|---|---|---|---|
| **PV for model weights** | Yes | 11GB to 8GB pull, ~1.5 min saved | Build |
| **GKE Secondary Boot Disk** | Yes, official GKE feature | 8GB pull to seconds | Build |
| eStargz / Stargz Snapshotter | No, GKE managed containerd blocks custom plugins | same as Image Streaming | Rejected |
| GKE Image Streaming (tried) | Worse, lazy remote IO kills Python/CUDA imports | negative | Reverted |
| DaemonSet pre-pull | No, cache dies with node on scale-to-zero | zero | Rejected |
| Artifact Registry optimization | No knobs available | zero | Rejected |
| min-1 GPU node always-on | Eliminates cold start, $0.70/hr ongoing | portfolio tradeoff too weak | Rejected |

## Chosen Plan: PV + Secondary Boot Disk

### Component 1: PersistentVolume for Model Weights

Remove model baking from the vLLM image. Store Qwen2.5-1.5B weights on a GCP
Persistent Disk (PVC) that survives pod restarts and node deletion.

**What changes:**
- vLLM image reverts to `vllm/vllm-openai:latest` (~8GB, no model weights)
- `k8s/vllm-pvc.yaml`: 10Gi PersistentVolumeClaim
- `k8s/vllm-model-init-job.yaml`: one-time Job that runs `snapshot_download` to
  populate the PVC on first deploy
- `k8s/vllm.yaml`: vLLM mounts PVC at `/root/.cache/huggingface` via `HF_HOME`

**Flow:**
```
First deploy only:
  init Job downloads Qwen2.5-1.5B (3.5GB from HuggingFace) and writes it to the PVC

Every cold start after:
  GPU node provisions, pulls 8GB vLLM image (~5 min)
  vLLM pod mounts PVC (weights already there) and loads model into VRAM (~2.5 min)
```

**PVC cost:** ~10Gi GCP pd-standard = ~$0.17/month.

### Component 2: GKE Secondary Boot Disk

A first-party GKE feature. Build a GCE disk image with the vLLM container layers
pre-extracted into containerd's image store. GPU nodes boot with this disk
attached; containerd finds the image already cached locally.

**Why this works where Image Streaming failed:**
- Image Streaming: container "starts" in 2s, but reads files lazily over the
  network during Python/CUDA import: thousands of remote reads = slow
- Secondary Boot Disk: data comes from a locally attached pd-ssd, so all reads
  are local disk I/O at full speed

**Build workflow** (`scripts/build-node-cache.sh`):
```bash
go run ./cli \
  --project-name=<PROJECT_ID> \
  --image-name=vllm-cache-v<VERSION> \
  --zone=us-central1-a \
  --gcs-path=gs://<LOG_BUCKET> \
  --disk-size-gb=20 \
  --container-image=us-docker.pkg.dev/<PROJECT_ID>/llm-gateway/vllm-openai:latest \
  --image-pull-auth=ServiceAccountToken \
  --timeout=40m
```

**Node pool flag:**
```bash
gcloud container node-pools create gpu-pool \
  ...existing flags... \
  --enable-image-streaming \
  --secondary-boot-disk=disk-image=global/images/vllm-cache-v<VERSION>,mode=CONTAINER_IMAGE_CACHE
```

**Requirements:**
- A GKE version with secondary boot disk support
- Node pool service account needs `roles/artifactregistry.reader`
- Disk size at least the uncompressed image size (~20GB)
- GCS bucket needed for build logs

**Operational overhead on vLLM version update:**
1. Build new disk image with new vLLM version
2. Create new node pool pointing to new disk image
3. Drain and delete old node pool

**Secondary boot disk cost:** ~20GB pd-standard per GPU node-hour, negligible
(GPU node is usually off with scale-to-zero).

## Combined Result

Hardware: GCP GKE, NVIDIA T4 Spot, n1-standard-4, us-east1-d.

| Phase | Baseline (11 GB baked) | After Opt 1 (PV only) | After Opt 1 + Opt 2 (PV + SBD) |
|---|---|---|---|
| GPU node provision | ~2.5 min | ~2.5 min | ~2.5 min |
| Container image pull | **~6.5 min** (11 GB) | **~5 min** (8 GB) | **~7s** (local disk) |
| vLLM boot + model load to VRAM | ~2 min (baked) | ~2.5 min (PVC to VRAM) | ~2.5 min (PVC to VRAM) |
| **Total** | **~11 min** | **~10 min** (estimated) | **~5.6 min** |
| **Savings vs baseline** | reference | **~1.5 min (~14%)** | **~5.4 min (about half)** |

> Note: the "PV only" column is computed from the 8 GB image-pull math plus observed
> PVC load time. The two optimizations were measured together. PV's main
> contribution is structural: it makes a stock 8 GB image cacheable on the
> secondary boot disk in the first place.

## Why the Remaining 5.6 min Cannot Easily Go Lower

| Phase | Duration | Why it stays |
|---|---|---|
| GCE boot + NVIDIA driver init | ~2.5 min | Outside GKE's control, hardware bring-up |
| Container start (image already local) | ~7s | Pod scheduler + containerd unpack |
| 3.5 GB model from PVC into VRAM | ~2.5 min | Network-attached PD bandwidth, not GPU-bound |

Further reduction requires either GPU-aware node warming (a min-1 idle GPU node,
which defeats scale-to-zero) or moving the model into a tmpfs / Local SSD on the
secondary boot disk itself (adds complexity and rebuild burden). Out of scope here.

## Implementation Status

- [x] PV for model weights: `k8s/vllm-pvc.yaml`, `k8s/vllm-model-init-job.yaml`, vLLM deployment mounts PVC
- [x] GKE Secondary Boot Disk: built via `scripts/build-node-cache.sh`
- [x] Cold start about 5.6 min end-to-end (recorded runs under `docs/runs/`)
