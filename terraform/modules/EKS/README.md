# EKS Module

## What is EKS?

Amazon Elastic Kubernetes Service (EKS) is a managed Kubernetes control plane. AWS runs the API server, etcd (the cluster database), and the scheduler for you — you only manage the worker nodes. Your microservice pods (auth, streaming, admin, chat, frontend, MongoDB) run on those worker nodes.

---

## What this module creates

### Overview

```
EKS Cluster (control plane — managed by AWS)
│
├── App Node Group (private app subnets — AZ-1a + AZ-1b)
│     t3.medium × 2–6 nodes
│     Runs: auth, streaming, admin, chat, frontend pods
│
└── Data Node Group (private data subnet — AZ-1a only)
      t3.medium × 1 node  [tainted: workload=database:NoSchedule]
      Runs: MongoDB StatefulSet pod only
```

---

### IAM Role — Control Plane (`aws_iam_role.cluster`)

EKS needs an IAM role to manage AWS resources on your behalf — for example, creating Elastic Network Interfaces (ENIs) in your subnets so the control plane can communicate with nodes. The `AmazonEKSClusterPolicy` managed policy grants exactly these permissions.

### `aws_eks_cluster`

The EKS control plane itself. Key settings:

- `subnet_ids` — includes **both** private app and private data subnets. This tells EKS where it can place control plane ENIs so it can reach nodes in either node group. This does NOT mean the control plane runs in these subnets — AWS manages that separately.
- `endpoint_private_access = true` — pods and nodes inside the VPC talk to the Kubernetes API server over the private network (no traffic leaves the VPC)
- `endpoint_public_access = true` — allows you to run `kubectl` from your laptop. You can restrict this to your IP CIDR for tighter security

### OIDC Provider (`aws_iam_openid_connect_provider`)

This is what makes **IRSA (IAM Roles for Service Accounts)** work.

Without IRSA, you would have to store `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` inside Kubernetes Secrets — which is insecure. With IRSA, a Kubernetes ServiceAccount is linked to an IAM Role. When a pod starts, it automatically receives short-lived AWS credentials via the AWS metadata service — no secrets stored anywhere.

The OIDC provider is the trust bridge between Kubernetes and IAM:
```
Pod starts with ServiceAccount "streaming-sa"
    │
    ▼
AWS sees the OIDC token from the EKS cluster
    │
    ▼
IAM trusts this token (because of the OIDC provider)
    │
    ▼
Pod assumes the "streaming-irsa-role" → gets S3 read access
```

### IAM Role — Worker Nodes (`aws_iam_role.node`)

All worker nodes (both app and data node groups) share this role. Three policies are attached:

| Policy | Why it is needed |
|---|---|
| `AmazonEKSWorkerNodePolicy` | Allows nodes to register with the EKS cluster and describe EC2 resources |
| `AmazonEKS_CNI_Policy` | Allows the VPC CNI plugin to assign VPC IP addresses directly to pods |
| `AmazonEC2ContainerRegistryReadOnly` | Allows nodes to pull Docker images from ECR |

### App Node Group (`aws_eks_node_group.app`)

- Placed in **private app subnets** (AZ-1a + AZ-1b) — two AZs for high availability
- Scales between `node_min` (2) and `node_max` (6) — the Cluster Autoscaler adjusts this based on pending pods
- `max_unavailable = 1` in `update_config` — during a node group update (e.g. AMI upgrade), only one node is replaced at a time so the cluster stays available
- No taint — all regular pods schedule here by default

### Data Node Group (`aws_eks_node_group.data`)

- Placed in the **private data subnet** (AZ-1a only) — network-isolated from app nodes
- Fixed at 1 node (min=1, max=1) — MongoDB does not autoscale
- **Taint:** `workload=database:NoSchedule`
  - Any pod that does NOT have a matching toleration is **rejected** by this node
  - This means auth, streaming, frontend etc. can never accidentally land here
- **Label:** `workload=database`
  - The MongoDB StatefulSet uses `nodeSelector: workload=database` to target this node specifically

The MongoDB pod must have both the toleration AND the nodeSelector:
```yaml
tolerations:
  - key: "workload"
    value: "database"
    effect: "NoSchedule"
nodeSelector:
  workload: database
```

---

## What is the difference between a taint and a label?

| | Taint | Label |
|---|---|---|
| Purpose | **Repels** pods from a node | **Attracts** pods to a node |
| Direction | Node pushes pods away | Pod selects a node |
| Used with | `tolerations` in pod spec | `nodeSelector` in pod spec |

You need both together: the taint stops everything else from landing on the data node, and the nodeSelector ensures MongoDB actively targets it.

---

## Inputs

| Variable | Type | Default | Description |
|---|---|---|---|
| `project` | string | `streamingapp` | Prefix for resource names |
| `cluster_name` | string | `streamingapp` | EKS cluster name |
| `cluster_version` | string | `1.29` | Kubernetes version |
| `private_app_subnet_ids` | list(string) | — | From VPC module — app node placement |
| `private_data_subnet_id` | string | — | From VPC module — data node placement |
| `node_instance_type` | string | `t3.medium` | EC2 type for app nodes |
| `data_node_instance_type` | string | `t3.medium` | EC2 type for data node |
| `node_min` | number | `2` | Min app nodes |
| `node_max` | number | `6` | Max app nodes |
| `node_desired` | number | `2` | Initial app node count |

## Outputs

| Output | Used by |
|---|---|
| `cluster_name` | `aws eks update-kubeconfig`, Helm, ArgoCD |
| `cluster_endpoint` | Kubernetes provider in `envs/prod/main.tf` |
| `cluster_ca_certificate` | Kubernetes provider in `envs/prod/main.tf` |
| `app_node_security_group_id` | ElastiCache module — allow port 6379 from app nodes |
| `data_node_security_group_id` | Security group rules — allow port 27017 from app nodes to data node |
| `oidc_provider_arn` | IRSA role trust policies for each service |
| `oidc_provider_url` | IRSA role trust policy `StringEquals` condition |

---

## Usage in envs/prod/main.tf

```hcl
module "eks" {
  source                  = "../../modules/EKS"
  project                 = "streamingapp"
  cluster_name            = "streamingapp"
  cluster_version         = "1.29"
  private_app_subnet_ids  = module.vpc.private_app_subnet_ids
  private_data_subnet_id  = module.vpc.private_data_subnet_id
  node_instance_type      = "t3.medium"
  data_node_instance_type = "t3.medium"
  node_min                = 2
  node_max                = 6
  node_desired            = 2
}
```

## After applying — connect kubectl to the cluster

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name streamingapp

kubectl get nodes
# NAME                          STATUS   ROLES    AGE
# ip-10-0-3-x.ec2.internal      Ready    <none>   2m   ← app node AZ-1a
# ip-10-0-4-x.ec2.internal      Ready    <none>   2m   ← app node AZ-1b
# ip-10-0-5-x.ec2.internal      Ready    <none>   2m   ← data node AZ-1a
```
