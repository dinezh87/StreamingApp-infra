# ECR Module

## What is ECR?

Amazon Elastic Container Registry (ECR) is a fully managed private Docker image registry. Instead of using Docker Hub, your CI/CD pipeline pushes built images to ECR, and EKS worker nodes pull from ECR when deploying pods. Access is controlled entirely through IAM — no passwords or tokens needed.

---

## What this module creates

### `aws_ecr_repository` (one per service)

A private repository for each microservice. Repositories are named `streamingapp/<service>`:

| Repository | Holds images for |
|---|---|
| `streamingapp/auth` | Auth service |
| `streamingapp/streaming` | Streaming service |
| `streamingapp/admin` | Admin service |
| `streamingapp/chat` | Chat service |
| `streamingapp/frontend` | React frontend (nginx) |

Key settings:
- `image_tag_mutability = "MUTABLE"` — allows overwriting tags like `latest`. You can change this to `IMMUTABLE` to enforce that every push uses a unique tag (e.g. git SHA), which is safer in production
- `scan_on_push = true` — every image is automatically scanned for OS and package vulnerabilities the moment it is pushed. Results appear in the ECR console under **Findings**

### `aws_ecr_lifecycle_policy` (one per repository)

Automatically deletes old images when a repository has more than 10. Without this, images accumulate indefinitely and storage costs grow over time. The policy applies to all tags (`tagStatus = "any"`), so both tagged releases and untagged intermediate builds are counted.

---

## How it fits into the pipeline

```
Developer pushes code to GitHub
        │
        ▼
Jenkins builds Docker image
docker build -t streamingapp/auth:abc123 .
        │
        ▼
Jenkins pushes to ECR
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/streamingapp/auth:abc123
        │
        ▼
Jenkins updates Helm values (image tag: abc123)
        │
        ▼
ArgoCD detects change → EKS pulls new image from ECR → rolling update
```

EKS nodes are granted `AmazonEC2ContainerRegistryReadOnly` via the node IAM role (set up in the EKS module), so they can pull images without any credentials stored in the cluster.

---

## Inputs

| Variable | Type | Default | Description |
|---|---|---|---|
| `project` | string | `streamingapp` | Prefix for repository names |
| `repos` | list(string) | `["auth","streaming","admin","chat","frontend"]` | One repository is created per entry |

## Outputs

| Output | Description |
|---|---|
| `repository_urls` | Map of `service → full ECR URL` — used in `values-prod.yaml` as the image registry |
| `repository_arns` | Map of `service → ARN` — used in IAM policies if you need fine-grained push/pull permissions |

---

## How to authenticate Docker with ECR before pushing

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  <account_id>.dkr.ecr.us-east-1.amazonaws.com
```

This token is valid for 12 hours. Jenkins runs this command at the start of every pipeline build.

---

## Usage in envs/prod/main.tf

```hcl
module "ecr" {
  source  = "../../modules/ECR"
  project = "streamingapp"
  repos   = ["auth", "streaming", "admin", "chat", "frontend"]
}

# Reference in other modules or outputs:
# module.ecr.repository_urls["auth"]
# → <account>.dkr.ecr.us-east-1.amazonaws.com/streamingapp/auth
```
