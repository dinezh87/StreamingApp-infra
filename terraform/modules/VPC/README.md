# VPC Module

## What is a VPC?

A Virtual Private Cloud (VPC) is your own isolated network inside AWS. Nothing can reach your resources unless you explicitly allow it. Think of it as the walls, rooms, and doors of your infrastructure — everything else (EKS, MongoDB, ElastiCache) lives inside it.

---

## What this module creates

### Network layout

```
VPC — 10.0.0.0/16
│
├── Public Subnet AZ-1a (10.0.1.0/24)      ← ALB nodes, NAT Gateway
├── Public Subnet AZ-1b (10.0.2.0/24)      ← ALB nodes, NAT Gateway
│
├── Private App Subnet AZ-1a (10.0.3.0/24) ← EKS app worker nodes
├── Private App Subnet AZ-1b (10.0.4.0/24) ← EKS app worker nodes
│
└── Private Data Subnet AZ-1a (10.0.5.0/24) ← EKS data node (MongoDB pod)
```

### Resources created

#### `aws_vpc`
The top-level network container. `enable_dns_hostnames` and `enable_dns_support` are both required for EKS — without them, nodes cannot resolve internal AWS service endpoints.

#### `aws_internet_gateway`
Attached to the VPC. Allows resources in **public subnets** to send and receive traffic from the internet. Resources in private subnets never touch the IGW directly.

#### `aws_subnet` — public (x2)
One in each AZ. The ALB and NAT Gateways live here. These subnets have a route to the IGW.

Two Kubernetes tags are applied:
- `kubernetes.io/role/elb = 1` — tells the AWS Load Balancer Controller to place the internet-facing ALB in these subnets

#### `aws_subnet` — private_app (x2)
One in each AZ. EKS worker nodes (app node group) run here. They have no public IP. They reach the internet (for ECR pulls, S3, Secrets Manager) via the NAT Gateway in the same AZ.

Tag applied:
- `kubernetes.io/role/internal-elb = 1` — tells the Load Balancer Controller it can place internal load balancers here if needed

#### `aws_subnet` — private_data (x1, AZ-1a only)
The EKS data node group (which runs the MongoDB pod) is placed here. This subnet has **no route to the internet at all** — not even via NAT. The MongoDB pod can only be reached from the app subnets via Security Group rules.

#### `aws_eip` + `aws_nat_gateway` (x2)
One NAT Gateway per AZ, each with its own Elastic IP. App nodes in AZ-1a route outbound traffic through the NAT in AZ-1a, and AZ-1b nodes through the NAT in AZ-1b. This means if one AZ goes down, the other AZ's nodes can still reach the internet. Using a single NAT Gateway would be cheaper but creates a cross-AZ dependency.

#### Route tables
| Route table | Attached to | Default route |
|---|---|---|
| `rt-public` | Both public subnets | → Internet Gateway |
| `rt-private-app-1a` | Private app subnet AZ-1a | → NAT Gateway AZ-1a |
| `rt-private-app-1b` | Private app subnet AZ-1b | → NAT Gateway AZ-1b |
| `rt-private-data` | Private data subnet | No default route (isolated) |

---

## Why two NAT Gateways instead of one?

If you use a single NAT Gateway in AZ-1a and AZ-1b goes down, the nodes in AZ-1b lose internet access too (because their traffic would have to cross to AZ-1a to reach the NAT). Two NAT Gateways keep each AZ self-sufficient. The trade-off is cost (~$32/month each).

---

## Inputs

| Variable | Type | Default | Description |
|---|---|---|---|
| `project` | string | `streamingapp` | Prefix for all resource names |
| `vpc_cidr` | string | `10.0.0.0/16` | CIDR block for the entire VPC |
| `public_subnet_cidrs` | list(string) | `["10.0.1.0/24","10.0.2.0/24"]` | One per AZ — public subnets |
| `private_app_subnet_cidrs` | list(string) | `["10.0.3.0/24","10.0.4.0/24"]` | One per AZ — EKS app nodes |
| `private_data_subnet_cidr` | string | `10.0.5.0/24` | Single AZ — EKS data node (MongoDB) |

## Outputs

| Output | Used by |
|---|---|
| `vpc_id` | EKS module — cluster and security groups need the VPC ID |
| `public_subnet_ids` | CloudFront / ALB module — ALB is placed in public subnets |
| `private_app_subnet_ids` | EKS module — app node group subnet placement |
| `private_data_subnet_id` | EKS module — data node group subnet placement |

---

## Usage in envs/prod/main.tf

```hcl
module "vpc" {
  source                   = "../../modules/VPC"
  project                  = "streamingapp"
  vpc_cidr                 = "10.0.0.0/16"
  public_subnet_cidrs      = ["10.0.1.0/24", "10.0.2.0/24"]
  private_app_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
  private_data_subnet_cidr = "10.0.5.0/24"
}
```
