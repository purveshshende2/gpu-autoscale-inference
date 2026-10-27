# Example full-cycle run: scale-to-zero GPU inference

This directory contains a representative run captured with
`scripts/full-cycle-run.sh` on GCP GKE (n1-standard-4 + NVIDIA T4 Spot,
us-east1-d). It demonstrates the complete scale-to-zero lifecycle:

1. **Pre-flight** — system at zero (no GPU node, no workers, no vLLM)
2. **Phase 1 — cold start** — continuous load into a cold system; KEDA scales
   pods on Redis queue depth; Cluster Autoscaler provisions the GPU node;
   vLLM loads the model from the PVC into VRAM
3. **Valley** — 60s pause, queue at zero
4. **Phase 2 — warm load** — identical load profile into a warm system;
   queue stays low, no cold-start overhead
5. **Cool down** — KEDA cooldown scales pods to zero; Cluster Autoscaler
   removes the GPU node; full zero state ($0/hr idle)

The raw logs show every layer: K8s events, KEDA scale-up/down, Redis queue
depth, pod lifecycle, node lifecycle, and streamed container logs.

## Key milestones (timeline.log)

```
T+15s  | PRE-FLIGHT COMPLETE - system at zero
T+15s  | PHASE 1 START - continuous load: 5 req/s x 180s (cold start)
T+196s | PHASE 1 FIRE STOP - 873 requests fired
T+595s | vLLM READY - cold start = 595s (~10 min)
T+884s | PHASE 1 DONE - queue drained to zero
T+959s | PHASE 2 START - continuous load: 5 req/s x 180s (warm GPU)
T+1265s| PHASE 2 DONE - 306s total (warm response time)
T+1609s| PODS SCALED TO ZERO - KEDA cooldown complete
T+2233s| GPU NODE REMOVED - Cluster Autoscaler scale-down
T+2233s| COOL DOWN COMPLETE - full zero state
```

## Regenerate the figures

```bash
pip install matplotlib
python scripts/plot_run.py docs/runs/run-20260406-190041 docs/run-20260406-190041.png
```

## Run your own cycle

```bash
# Deploy to GCP GKE
export GCP_PROJECT=<your-gcp-project-id>
./scripts/deploy-gcp.sh

# Run the full-cycle demo (captures logs under data/)
./scripts/full-cycle-run.sh <GATEWAY_IP>

# Tear down when done
./scripts/destroy-gcp.sh
```
