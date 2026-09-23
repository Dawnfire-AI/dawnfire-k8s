# B300 Cluster Handbook

How to get onto the shared training cluster, grab GPUs, and work on them. You log in with
your usual SSO account; there is no shared key or password. GPUs are handed out through a
queue, so asking for more than is free simply waits its turn.

| | |
|---|---|
| GPUs | 32: 4 nodes, 8 NVIDIA B300 each, 275 GB per GPU |
| Network | 8 × 800 Gb/s InfiniBand XDR per node |
| Storage | 100 TiB shared at `/data` |
| Session limit | 8 hours by default |

What is in this repo:

| File | What it is for |
|---|---|
| `setup-kubeconfig.sh` | One-time: adds the cluster to your `~/.kube/config` |
| `submit-job.sh` | Starts a GPU session (one node or several) that you shell into |
| `examples/trainjob.yaml` | Template for an unattended batch training job |

## 1. Get access

You need to be in the SSO group **Train K8s Users**. Ask an admin to add you. It mirrors
the Google Workspace group `train-k8s-user`, so that is where membership is changed; a
change can take a little while to reach the cluster.

Install the tools and add the cluster to your normal kubeconfig. The script writes a
`training` context into `~/.kube/config` next to whatever you already have and makes it
your default context, so every `kubectl` command below talks to this cluster. Your other
contexts are not changed, and nothing in it is a secret.

```sh
brew install kubectl kubelogin
./setup-kubeconfig.sh
kubectl auth whoami
```

The last command opens **sso.dawnfire.ai** in your browser; after you log in it finishes
on its own. You should see your email as `oidc:you@dawnfire.ai`, with
`oidc:Train K8s Users` among the groups. From then on you stay logged in for about 30 days
without seeing the browser again. On a machine with no browser, run
`DEVICE_CODE=1 ./setup-kubeconfig.sh` instead and open the printed link on any device.

If you switch to another cluster later, `kubectl config use-context training` switches
back. `submit-job.sh` always targets `training`, whatever your current context is.

## 2. Start a GPU session

A session is a set of pods holding GPUs and doing nothing until you connect, much like
renting a box you then ssh into. `submit-job.sh` creates one:

```sh
./submit-job.sh <name> <nodes> [gpus-per-node] [image]

./submit-job.sh dev 1 1     # 1 node, 1 GPU
./submit-job.sh dev 1       # 1 node, all 8 GPUs
./submit-job.sh run 2       # 2 nodes, 16 GPUs
```

Every job name on the cluster starts with **your username**: the part of your email
before `@`, lowercased, with dots turned into `-` (`alice.chen@dawnfire.ai` is
`alice-chen`). The script adds it for you, so `dev` becomes `yourname-dev`, and prints the
exact names to use afterwards. Below, `yourname` stands for yours.

CPU and memory are sized to the GPU count for you
(22 CPU and 300Gi per GPU). The default image is `nvcr.io/nvidia/pytorch:26.08-py3`, with
CUDA, NCCL, Python and torch; pass another as the fourth argument. `/data`, a 128Gi
`/dev/shm` and InfiniBand are always set up.

```sh
kubectl get pods -w
```

If no pod appears straight away, you are **queued** behind someone else's GPUs. That is
the system working, not a failure; it starts by itself once enough GPUs free up. The first
start on a node also takes about 3 minutes while the image downloads.

Sessions stop by themselves after **8 hours** of running (time spent queued does not
count). For longer, `MAX_HOURS=24 ./submit-job.sh ...`.

## 3. Get a shell (the "ssh")

Once the pods show `Running`:

```sh
kubectl exec -it yourname-dev-master-0 -- bash
```

Inside, check you got the cards:

```sh
nvidia-smi
python -c "import torch; print(torch.cuda.device_count())"
```

Open as many shells as you like by running the same `exec` in other terminals. Closing a
shell does not stop the session; only deleting it does (see [Clean up](#8-clean-up)).

## 4. Multi-node sessions

With 2 or more nodes the pods are `<name>-master-0`, `<name>-worker-0`,
`<name>-worker-1`, and so on. Open a shell on **each** and start the same command on all
of them:

```sh
kubectl exec -it yourname-run-master-0 -- bash
kubectl exec -it yourname-run-worker-0 -- bash

# on every pod:
torchrun --nnodes=$K8S_WORLD_SIZE --node_rank=$K8S_RANK --nproc_per_node=8 \
  --master_addr=$K8S_MASTER_ADDR --master_port=$K8S_MASTER_PORT \
  /data/yourname/my-project/train.py
```

The connection details are saved under `K8S_*` rather than the usual names, so they do
not collide with frameworks that set their own. NCCL finds InfiniBand on its own; no
extra settings are needed. Measured all-reduce bus bandwidth between two nodes is about
890 GB/s.

## 5. Your files: `/data`

Every pod mounts the same 100 TiB filesystem at `/data`. A file written on one node is
immediately visible on all the others, so this is where code, datasets and checkpoints go.

```sh
mkdir -p /data/$USER
```

> **Everything outside `/data` is lost when the pod ends.** `/data` also has no
> per-person quota and no backups: keep to your own directory, and copy anything
> irreplaceable somewhere safe.

For small transfers from your laptop:

```sh
kubectl cp ./notes.txt yourname-dev-master-0:/data/yourname/
```

## 6. Watch the queue

The live queue dashboard is at **https://kueue.baiji-pleco.ts.net**. It needs Tailscale;
the cluster itself does not. It shows every job, which are running and which are waiting,
and how much of the 32-GPU quota is in use. It shows job names, not who submitted them.

From the terminal, with the submitter of each job:

```sh
kubectl get workloads -L dawnfire.ai/owner   # everything queued or running
kubectl describe workload                     # why yours is still waiting
```

## 7. Batch training jobs

When your script is ready to run unattended, submit it as a `TrainJob`. It runs your
command under `torchrun` on every node and stops when the script exits. Copy
`examples/trainjob.yaml`, change the name, node count and command. Here you write the
name yourself, and it must start with `yourname-` too; the cluster rejects anything else
and says which prefix it wants.

```yaml
apiVersion: trainer.kubeflow.org/v1alpha1
kind: TrainJob
metadata:
  name: yourname-train
  namespace: training
spec:
  runtimeRef:
    name: torch-shared           # mounts /data and a large /dev/shm
  trainer:
    numNodes: 2
    resourcesPerNode:
      requests: &res { cpu: "176", memory: 2400Gi, nvidia.com/gpu: 8, rdma/shared_ib: 1 }
      limits: *res
    command: ["python", "/data/yourname/my-project/train.py"]
```

```sh
kubectl apply -f my-train.yaml
kubectl get trainjob
kubectl logs -f -l jobset.sigs.k8s.io/jobset-name=yourname-train
```

Your script receives the usual `RANK`, `LOCAL_RANK`, `WORLD_SIZE` and `MASTER_ADDR` from
torchrun. Write the command as `python your_script.py` and leave the launching to the
runtime: starting torchrun yourself inside it would launch twice.

## 8. Clean up

**Delete your session when you stop working.** An idle shell holds its GPUs just as
firmly as a busy one, and nobody else can use them meanwhile.

```sh
kubectl delete pytorchjob yourname-dev     # a session from submit-job.sh
kubectl delete trainjob yourname-train     # a batch job
```

Sessions stop by themselves after 8 hours as a safety net. Do not rely on it.

## House rules

- Ask for the GPUs you will actually use. Eight idle GPUs is a quarter of the cluster.
- One session at a time unless you have said otherwise in the team channel.
- Delete sessions you are done with.
- Work in `/data/$USER`, not at the top of `/data`.

## Troubleshooting

| What you see | What it means |
|---|---|
| No pod, or the job shows as suspended | You are queued. It starts when enough GPUs are free. `describe workload` says what it is waiting for. |
| `job names in this namespace must start with "yourname-"` | The job's name lacks your username prefix. Rename it as the message suggests. |
| Pod stuck in `ContainerCreating` for a few minutes | First image download on that node. Wait. |
| `Forbidden` on everything | Your login does not carry **Train K8s Users**. Check with `kubectl auth whoami`. If the group is missing, ask an admin to add you to `train-k8s-user` in Google Workspace, then run `kubectl oidc-login clean` and any command to log in again. |
| The browser never opens, or you are on a machine without one | Re-run `DEVICE_CODE=1 ./setup-kubeconfig.sh`. You will get a link and code to open on any device. |
| NCCL falls back to sockets, or InfiniBand errors | The pod is missing `rdma/shared_ib: 1` or the `IPC_LOCK` capability. `submit-job.sh` and `torch-shared` set both. |
| DataLoader workers killed | The pod has no large `/dev/shm`. Use `submit-job.sh` or the `torch-shared` runtime, which both provide one. |
| `init_process_group` fails in a TrainJob | The command bypasses torchrun. Use `python your_script.py`, not a wrapper that launches its own processes. |

Questions go to the infra channel. Cluster changes are made in the infra repo under
`stacks/poc-training-cluster`.
