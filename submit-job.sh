#!/usr/bin/env bash
# Submit a long-running multi-node shell to the training cluster, then exec into it and
# launch training by hand. This is the same working model as the EKS submit-job.sh, with
# the EKS-specific parts dropped: no instance-type selector (Kueue's ResourceFlavor pins
# the job to GPU nodes), no hostNetwork (InfiniBand works in the pod network namespace
# here, unlike EFA), and no rendezvous port argument (nothing shares a host port, so
# concurrent jobs cannot collide on one).
set -euo pipefail

DEFAULT_IMAGE="nvcr.io/nvidia/pytorch:26.08-py3"
DEFAULT_GPUS=8

# Pin submissions to this cluster so they cannot land on whatever kubectl context happens
# to be active. "training" is the SSO context the handbook's kubectl config commands create.
# Override with KUBE_CONTEXT=... if you really mean to.
KUBE_CONTEXT="${KUBE_CONTEXT:-training}"
NAMESPACE="${NAMESPACE:-training}"
QUEUE="${QUEUE:-gpu}"
# The job stops by itself after this many hours of running, so a forgotten session cannot
# hold its GPUs forever. Time spent queued does not count.
MAX_HOURS="${MAX_HOURS:-8}"

usage() {
  cat <<USAGE
Usage: $0 <job-name> <total-nodes> [gpus-per-node] [image]
  job-name        Name for the PyTorchJob
  total-nodes     Total nodes, master + workers (minimum 1)
  gpus-per-node   GPUs per node (default: ${DEFAULT_GPUS}, max 8)
  image           Container image (default: ${DEFAULT_IMAGE})

The job stops by itself after MAX_HOURS hours of running (currently ${MAX_HOURS}).
Set MAX_HOURS=12 ./submit-job.sh ... to change it.

The cluster has 4 nodes of 8 GPUs. Asking for more than is free does not fail: Kueue
queues the job until it fits. Watch it with:
  kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} get workloads
or open the dashboard at https://kueue.baiji-pleco.ts.net
USAGE
  exit 1
}

[[ $# -lt 2 || $# -gt 4 ]] && usage

JOB_NAME="$1"
TOTAL_NODES="$2"
GPUS="${3:-$DEFAULT_GPUS}"
IMAGE="${4:-$DEFAULT_IMAGE}"

[[ "$TOTAL_NODES" =~ ^[0-9]+$ ]] && [[ "$TOTAL_NODES" -ge 1 ]] || { echo "Error: total-nodes must be an integer >= 1"; exit 1; }
[[ "$GPUS" =~ ^[0-9]+$ ]] && [[ "$GPUS" -ge 1 ]] && [[ "$GPUS" -le 8 ]] || { echo "Error: gpus-per-node must be 1-8"; exit 1; }
[[ "$MAX_HOURS" =~ ^[0-9]+$ ]] && [[ "$MAX_HOURS" -ge 1 ]] || { echo "Error: MAX_HOURS must be an integer >= 1"; exit 1; }

WORKER_REPLICAS=$((TOTAL_NODES - 1))

# CPU and memory are scaled to the GPU count so a 1-GPU job does not reserve a whole node
# of quota. A node has 191.9 allocatable CPU and about 2662Gi.
CPU=$((GPUS * 22))
MEM=$((GPUS * 300))Gi

# Master and Worker pod specs must stay identical, so the block is written once and
# substituted into both. IFS= is load bearing: without it `read` strips the leading
# whitespace off the first line and the YAML comes out with `volumes:` unindented.
IFS= read -r -d '' POD_SPEC <<PODSPEC || true
          volumes:
          - name: shared
            persistentVolumeClaim:
              claimName: shared
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: 128Gi
          containers:
          - name: pytorch
            image: ${IMAGE}
            imagePullPolicy: IfNotPresent
            securityContext:
              capabilities:
                add: ["IPC_LOCK"]
            command: ["bash", "-c"]
            args:
            - |
              # The operator injects MASTER_ADDR, MASTER_PORT, WORLD_SIZE and RANK. Move
              # them aside so training frameworks that set their own do not conflict.
              #
              # This is done twice on purpose. Appending to .bashrc covers kubectl exec
              # sessions, but sourcing .bashrc here would NOT cover this script: stock
              # .bashrc opens with a test on PS1 that returns early, so in a
              # non-interactive shell it never reaches anything appended to it. The
              # entrypoint therefore does the remap directly as well.
              #
              # Note for anyone editing this block: it lives inside an unquoted heredoc,
              # so backticks here would be run as commands when the YAML is generated.
              # Keep this text backtick-free.
              export K8S_MASTER_ADDR="\$MASTER_ADDR"
              export K8S_MASTER_PORT="\$MASTER_PORT"
              export K8S_WORLD_SIZE="\$WORLD_SIZE"
              export K8S_RANK="\$RANK"
              unset MASTER_ADDR MASTER_PORT WORLD_SIZE RANK

              cat >> /root/.bashrc <<'REMAP'
              export K8S_MASTER_ADDR="\$MASTER_ADDR"
              export K8S_MASTER_PORT="\$MASTER_PORT"
              export K8S_WORLD_SIZE="\$WORLD_SIZE"
              export K8S_RANK="\$RANK"
              unset MASTER_ADDR MASTER_PORT WORLD_SIZE RANK
              REMAP

              echo "node \$(hostname)  rank \${K8S_RANK}/\${K8S_WORLD_SIZE}  master \${K8S_MASTER_ADDR}:\${K8S_MASTER_PORT}"
              nvidia-smi --query-gpu=index,name --format=csv,noheader || true

              trap 'kill \$(jobs -p) 2>/dev/null; wait' SIGTERM SIGINT
              while true; do wait -n 2>/dev/null || sleep 1; done
            resources:
              requests: { cpu: "${CPU}", memory: ${MEM}, nvidia.com/gpu: ${GPUS}, rdma/shared_ib: 1 }
              limits:   { cpu: "${CPU}", memory: ${MEM}, nvidia.com/gpu: ${GPUS}, rdma/shared_ib: 1 }
            volumeMounts:
            - { name: shared, mountPath: /data }
            - { name: dshm, mountPath: /dev/shm }
PODSPEC

WORKER_SECTION=""
if [[ "$WORKER_REPLICAS" -gt 0 ]]; then
  WORKER_SECTION=$(cat <<WORKER
    Worker:
      replicas: ${WORKER_REPLICAS}
      restartPolicy: OnFailure
      template:
        spec:
${POD_SPEC}
WORKER
)
fi

YAML=$(cat <<EOF
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    kueue.x-k8s.io/queue-name: ${QUEUE}
spec:
  runPolicy:
    activeDeadlineSeconds: $((MAX_HOURS * 3600))
    ttlSecondsAfterFinished: 3600
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: Never
      template:
        spec:
${POD_SPEC}
${WORKER_SECTION}
EOF
)

echo "Submitting PyTorchJob '${JOB_NAME}': ${TOTAL_NODES} node(s), ${GPUS} GPU each, image ${IMAGE}, stops after ${MAX_HOURS}h"
echo "Context: ${KUBE_CONTEXT}   namespace: ${NAMESPACE}   queue: ${QUEUE}"
echo "---"
echo "$YAML"
echo "---"
echo "$YAML" | kubectl --context "${KUBE_CONTEXT}" apply -f -

cat <<DONE

Submitted. It may sit queued until the GPUs are free; that is Kueue working, not a failure.

  kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} get workloads
  kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} get pods -w
  kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} exec -it ${JOB_NAME}-master-0 -- bash

Delete it when you are done. It holds its GPUs until you do, or until it hits the
${MAX_HOURS}h limit:
  kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} delete pytorchjob ${JOB_NAME}
DONE
