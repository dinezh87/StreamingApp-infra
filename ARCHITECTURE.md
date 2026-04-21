# StreamingApp — AWS Production Architecture

This document describes the production-grade AWS architecture for the StreamingApp microservices platform. It covers every AWS component, why it was chosen, how traffic flows through the system, and how it maps to the local Minikube setup.

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                          INTERNET                                                │
└──────────────────────────────────────────┬───────────────────────────────────────────────────────┘
                                           │
                                           ▼
                               ┌───────────────────────┐
                               │       Route 53        │
                               │ streamingapp.online DNS│
                               │  A record → CloudFront │
                               │  (Hosted Zone only —  │
                               │  domain registered in │
                               │      GoDaddy)         │
                               └───────────┬───────────┘
                                           │
                                           ▼
                               ┌───────────────────────┐
                               │      CloudFront        │
                               │  Global CDN            │
                               │                        │
                               │  Origin 1: S3 (OAC)   │
                               │  → /videos/*           │
                               │  → /thumbnails/*       │
                               │                        │
                               │  Origin 2: ALB         │
                               │  → /api/*              │
                               │  → /socket.io/*        │
                               │  → /* (frontend)       │
                               └───────────┬───────────┘
                                           │
                                           ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│  VPC  (10.0.0.0/16)                                                                             │
│  Region: us-east-1                                                                              │
│                                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────────────────────┐  │
│  │  Internet Gateway (IGW)                                                                   │  │
│  └───────────────────────────────────────┬───────────────────────────────────────────────────┘  │
│                                          │                                                      │
│                    ┌─────────────────────┴──────────────────────┐                              │
│                    │                                            │                              │
│   ┌────────────────▼──────────────────┐  ┌─────────────────────▼─────────────────┐            │
│   │     Public Subnet — AZ us-east-1a │  │     Public Subnet — AZ us-east-1b     │            │
│   │     10.0.1.0/24                   │  │     10.0.2.0/24                        │            │
│   │                                   │  │                                        │            │
│   │   ┌───────────────────────────┐   │  │   ┌───────────────────────────────┐   │            │
│   │   │     NAT Gateway (AZ-1a)   │   │  │   │     NAT Gateway (AZ-1b)       │   │            │
│   │   │     Elastic IP            │   │  │   │     Elastic IP                │   │            │
│   │   └───────────────────────────┘   │  │   └───────────────────────────────┘   │            │
│   │                                   │  │                                        │            │
│   │   ┌───────────────────────────┐   │  │   ┌───────────────────────────────┐   │            │
│   │   │   ALB Node (AZ-1a)        │   │  │   │   ALB Node (AZ-1b)            │   │            │
│   │   │   Port 443 (HTTPS)        │   │  │   │   Port 443 (HTTPS)            │   │            │
│   │   │   Port 80 → 443 redirect  │   │  │   │   Port 80 → 443 redirect      │   │            │
│   │   └───────────────────────────┘   │  │   └───────────────────────────────┘   │            │
│   └───────────────────────────────────┘  └────────────────────────────────────────┘            │
│                    │                                            │                              │
│                    └─────────────────────┬──────────────────────┘                              │
│                                          │                                                      │
│                                          ▼                                                      │
│                    ┌─────────────────────────────────────────────┐                              │
│                    │     Application Load Balancer (ALB)         │                              │
│                    │     Managed by AWS Load Balancer Controller  │                              │
│                    │     ACM Certificate — streamingapp.online    │                              │
│                    │                                             │                              │
│                    │  Listener Rules (path-based):               │                              │
│                    │  /api/auth/*    → auth-service:3001         │                              │
│                    │  /api/admin/*   → admin-service:3003        │                              │
│                    │  /api/streaming/* → streaming-service:3002  │                              │
│                    │  /api/chat/*    → chat-service:3004         │                              │
│                    │  /socket.io/*   → chat-service:3004         │                              │
│                    │  /*             → frontend-service:80       │                              │
│                    └─────────────────────┬───────────────────────┘                              │
│                                          │                                                      │
│                    ┌─────────────────────┴──────────────────────┐                              │
│                    │                                            │                              │
│   ┌────────────────▼──────────────────┐  ┌─────────────────────▼─────────────────┐            │
│   │  Private Subnet — App — AZ-1a     │  │  Private Subnet — App — AZ-1b         │            │
│   │  10.0.3.0/24                      │  │  10.0.4.0/24                           │            │
│   │                                   │  │                                        │            │
│   │  ┌─────────────────────────────┐  │  │  ┌─────────────────────────────────┐  │            │
│   │  │   EKS Worker Node 1         │  │  │  │   EKS Worker Node 2             │  │            │
│   │  │   t3.medium (min)           │  │  │  │   t3.medium (min)               │  │            │
│   │  │   Managed Node Group        │  │  │  │   Managed Node Group            │  │            │
│   │  │                             │  │  │  │                                 │  │            │
│   │  │  ┌────────────────────────┐ │  │  │  │  ┌────────────────────────┐    │  │            │
│   │  │  │  Namespace: streamingapp│ │  │  │  │  │  Namespace: streamingapp│    │  │            │
│   │  │  │                        │ │  │  │  │  │                        │    │  │            │
│   │  │  │  auth pod              │ │  │  │  │  │  auth pod              │    │  │            │
│   │  │  │  admin pod             │ │  │  │  │  │  admin pod             │    │  │            │
│   │  │  │  streaming pod         │ │  │  │  │  │  streaming pod         │    │  │            │
│   │  │  │  chat pod              │ │  │  │  │  │  chat pod              │    │  │            │
│   │  │  │  frontend pod          │ │  │  │  │  │  frontend pod          │    │  │            │
│   │  │  └────────────────────────┘ │  │  │  │  └────────────────────────┘    │  │            │
│   │  └─────────────────────────────┘  │  │  └─────────────────────────────────┘  │            │
│   └───────────────────────────────────┘  └────────────────────────────────────────┘            │
│                    │                                            │                              │
│                    └─────────────────────┬──────────────────────┘                              │
│                                          │                                                      │
│   ┌────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │  Private Subnet — Data — AZ-1a only (10.0.5.0/24)                                     │   │
│   │                                                                                        │   │
│   │  ┌─────────────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │  EKS Data Node Group (1 node — tainted: workload=database:NoSchedule)           │  │   │
│   │  │  t3.medium                                                                      │  │   │
│   │  │                                                                                 │  │   │
│   │  │  ┌───────────────────────────────────────────────────────────────────────────┐ │  │   │
│   │  │  │  MongoDB StatefulSet pod                                                  │ │  │   │
│   │  │  │  toleration: workload=database                                            │ │  │   │
│   │  │  │  nodeSelector: workload=database                                          │ │  │   │
│   │  │  │  EBS PersistentVolume (EBS CSI driver) — 20GB                             │ │  │   │
│   │  │  │  Port 27017 — reachable from app node group only via Security Group       │ │  │   │
│   │  │  └───────────────────────────────────────────────────────────────────────────┘ │  │   │
│   │  └─────────────────────────────────────────────────────────────────────────────────┘  │   │
│   └────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│  AWS Managed Services (Global / Regional — outside VPC)                                         │
│                                                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │     S3       │  │     ECR      │  │   Secrets    │  │ CloudWatch   │  │      ACM         │  │
│  │              │  │              │  │   Manager    │  │              │  │                  │  │
│  │ /videos/*    │  │ streamingapp/│  │              │  │ Logs         │  │ SSL Certificate  │  │
│  │ /thumbnails/*│  │  auth        │  │ JWT_SECRET   │  │ Metrics      │  │streamingapp.online│ │
│  │              │  │  streaming   │  │ DB_URI       │  │ Alarms       │  │ Auto-renewed     │  │
│  │ Bucket Policy│  │  admin       │  │ AWS_KEY_ID   │  │ Dashboards   │  │                  │  │
│  │ CloudFront   │  │  chat        │  │ AWS_SECRET   │  │ Container    │  │                  │  │
│  │ OAC only     │  │  frontend    │  │              │  │ Insights     │  │                  │  │
│  │              │  │              │  │ Pulled via   │  │              │  │                  │  │
│  │ Versioning   │  │ Image scan   │  │ IRSA at pod  │  │              │  │                  │  │
│  │ enabled      │  │ on push      │  │ startup      │  │              │  │                  │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────────┘  │
│                                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│  CI/CD Pipeline                                                                                 │
│                                                                                                 │
│  GitHub Repo          Jenkins (EC2)          ECR                  EKS (ArgoCD)                 │
│  (source code)   →   Build + Test       →   Push Image       →   GitOps Sync                  │
│       │               Trivy Scan             Tag: git SHA         Helm Upgrade                 │
│       │               Docker Build                                                             │
│       └──────────────► GitOps Repo ──────────────────────────────► ArgoCD watches             │
│                        (helm values)                                values.yaml                │
│                        image tag bump                               auto deploys               │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## DNS Setup — GoDaddy + Route 53

The domain `streamingapp.online` is registered in **GoDaddy**. AWS Route 53 is used only as the **DNS hosting provider** (Hosted Zone). You must delegate DNS from GoDaddy to Route 53 nameservers.

```
GoDaddy (registrar)
  └─► Nameservers updated to Route 53 NS records
         │
         ▼
Route 53 Hosted Zone — streamingapp.online
  └─► A record (Alias) → CloudFront distribution
  └─► CNAME records    → ACM DNS validation
```

Steps to delegate:
1. Create a **Hosted Zone** in Route 53 for `streamingapp.online`
2. Copy the 4 NS records Route 53 provides (e.g. `ns-123.awsdns-45.com`)
3. In **GoDaddy → DNS → Nameservers**, switch to **Custom** and paste the 4 Route 53 NS records
4. DNS propagation takes 10–30 minutes

---

## Traffic Flow — Step by Step

### User Watching a Video

```
1. User opens https://streamingapp.online
   └─► GoDaddy delegates to Route 53 → resolves to CloudFront distribution

2. Browser requests the React app (HTML/JS/CSS)
   └─► CloudFront → ALB → frontend pod (nginx) → serves index.html

3. React app loads, calls GET /api/streaming/videos
   └─► CloudFront → ALB → streaming pod → MongoDB → returns video list

4. User clicks a video thumbnail image
   └─► CloudFront → S3 (via OAC) → returns thumbnail directly from S3
       (does NOT go through any pod — CloudFront serves it from edge cache)

5. User clicks Play
   └─► CloudFront → ALB → streaming pod → S3 GetObject (range request)
       → streams video bytes back to browser in chunks

6. Chat panel connects
   └─► CloudFront → ALB → chat pod (WebSocket upgrade on /socket.io)
       → Socket.IO connection established
       → messages broadcast to all users watching the same video
```

### Admin Uploading a Video

```
1. Admin logs in at /login
   └─► ALB → auth pod → MongoDB → JWT issued with role: admin

2. Admin opens Upload Video form
   └─► ALB → admin pod → returns presigned S3 URL (valid 1 hour)

3. Browser uploads video file directly to S3 using presigned URL
   └─► Browser → S3 (direct, bypasses all pods and ALB)
       (large file upload never touches EKS)

4. Admin submits video metadata (title, description, genre etc.)
   └─► ALB → admin pod → MongoDB → video record created
```

---

## VPC Subnet Design

| Subnet | CIDR | AZ | Purpose |
|---|---|---|---|
| Public AZ-1a | 10.0.1.0/24 | us-east-1a | NAT Gateway, ALB nodes |
| Public AZ-1b | 10.0.2.0/24 | us-east-1b | NAT Gateway, ALB nodes |
| Private App AZ-1a | 10.0.3.0/24 | us-east-1a | EKS worker nodes |
| Private App AZ-1b | 10.0.4.0/24 | us-east-1b | EKS worker nodes |
| Private Data AZ-1a | 10.0.5.0/24 | us-east-1a | EKS data node group (MongoDB pod) |

**Why three tiers of subnets:**
- Public subnets hold only the ALB and NAT Gateways — nothing with application logic is publicly reachable
- Private App subnets hold EKS app worker nodes — they reach the internet via NAT Gateway for pulling ECR images and calling S3/Secrets Manager
- Private Data subnet holds a dedicated tainted EKS node group — no internet route, only the MongoDB pod is scheduled here via taint/toleration

---

## EKS Cluster Design

### App Node Group (private app subnets — us-east-1a + us-east-1b)

| Setting | Value | Reason |
|---|---|---|
| Instance type | t3.medium | 2 vCPU, 4GB RAM — sufficient for Node.js microservices |
| Min nodes | 2 | One per AZ for high availability |
| Max nodes | 6 | Allows HPA to scale out under load |
| Node placement | Private App subnets | No public IP on worker nodes |
| AMI | Amazon Linux 2 EKS optimised | Managed by AWS, auto-patched |

### Data Node Group (private data subnet — us-east-1a only)

| Setting | Value | Reason |
|---|---|---|
| Instance type | t3.medium | Sufficient for MongoDB with EBS volume |
| Fixed size | 1 | Single MongoDB instance — no autoscaling |
| Node placement | Private Data subnet | Network-isolated from app nodes |
| Taint | `workload=database:NoSchedule` | Repels all pods except MongoDB StatefulSet |
| Label | `workload=database` | MongoDB uses nodeSelector to target this node |

### Pod Replicas per Service

| Service | Min Replicas | Max Replicas (HPA) | Reason |
|---|---|---|---|
| frontend | 2 | 6 | Stateless nginx — scales easily |
| auth | 2 | 4 | Stateless JWT — scales easily |
| streaming | 2 | 6 | Video serving is CPU/bandwidth intensive |
| admin | 1 | 2 | Low traffic — admin users only |
| chat | 2 | 4 | WebSocket — needs Redis adapter for multi-pod |

### Key EKS Add-ons

| Add-on | Purpose |
|---|---|
| AWS Load Balancer Controller | Creates and manages the ALB from Kubernetes Ingress annotations |
| EBS CSI Driver | Provides PersistentVolumes backed by EBS |
| CoreDNS | Internal DNS — resolves `auth-service.streamingapp.svc.cluster.local` |
| kube-proxy | Network rules for ClusterIP services |
| Amazon VPC CNI | Assigns VPC IPs directly to pods — no overlay network overhead |

---

## AWS Services — What Replaces What

| Minikube | AWS | Why the Change |
|---|---|---|
| nginx Ingress Controller | ALB + AWS Load Balancer Controller | Native AWS load balancer, integrates with ACM for HTTPS, auto-scales, health checks built in |
| Local Docker daemon | ECR (Elastic Container Registry) | Private registry with IAM access control, vulnerability scanning on push, integrated with EKS |
| MongoDB StatefulSet + hostPath PV | MongoDB StatefulSet on EKS data node group (private data subnet) | Network-isolated via taint/toleration, EBS PersistentVolume via EBS CSI driver, full MongoDB compatibility |
| Kubernetes Secrets (base64) | AWS Secrets Manager | Encrypted at rest with KMS, IAM-controlled access, secret rotation support |
| minikube tunnel on localhost | GoDaddy → Route 53 → CloudFront + ACM | Real domain, HTTPS, global CDN, DDoS protection via AWS Shield Standard |
| No CDN | CloudFront | Caches video and thumbnail content at edge locations globally — reduces latency and S3 egress costs |
| No caching | ElastiCache Redis | Socket.IO multi-pod session sharing, JWT blacklisting on logout |
| No monitoring | CloudWatch + Container Insights | Centralised logs, metrics, alarms for all pods and AWS services |
| imagePullPolicy: Never | ECR pull via IRSA | Images pulled securely from ECR using IAM role — no credentials needed |

---

## Security Design

### Security Groups

| Security Group | Inbound | Outbound |
|---|---|---|
| ALB SG | 443 from 0.0.0.0/0, 80 from 0.0.0.0/0 | All to EKS Node SG |
| App Node SG | All from ALB SG, all from within App Node SG | Port 27017 to Data Node SG, all to internet via NAT |
| Data Node SG | Port 27017 from App Node SG only | None |
| ElastiCache SG | 6379 from EKS Node SG only | None |

### IRSA — IAM Roles for Service Accounts

Instead of storing `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in ConfigMaps or Secrets, each Kubernetes ServiceAccount is bound to an IAM role. The pod automatically receives temporary credentials via the AWS metadata service.

```
streaming pod  ──► IRSA Role ──► S3 GetObject (videos/*, thumbnails/*)
admin pod      ──► IRSA Role ──► S3 PutObject, DeleteObject (videos/*, thumbnails/*)
auth pod       ──► IRSA Role ──► Secrets Manager GetSecretValue (JWT_SECRET)
all pods       ──► IRSA Role ──► CloudWatch Logs PutLogEvents
EKS nodes      ──► IRSA Role ──► ECR GetAuthorizationToken, BatchGetImage
```

This eliminates all long-lived AWS credentials from the application entirely.

### S3 Bucket Policy

The S3 bucket is private. Access is granted only via:
- **CloudFront OAC (Origin Access Control)** — CloudFront can read objects to serve to users
- **IRSA role for admin pod** — can write new videos and thumbnails
- **IRSA role for streaming pod** — can read videos and thumbnails for streaming

---

## CloudFront Configuration

| Setting | Value | Reason |
|---|---|---|
| Origins | S3 (OAC) + ALB | S3 for static assets, ALB for API and frontend |
| Cache behaviour `/videos/*` | TTL 24h, compress | Videos rarely change after upload |
| Cache behaviour `/thumbnails/*` | TTL 24h, compress | Same |
| Cache behaviour `/api/*` | TTL 0 (no cache) | API responses must not be cached |
| Cache behaviour `/socket.io/*` | TTL 0, WebSocket enabled | Real-time — must not be cached |
| Cache behaviour `/*` | TTL 1h | Frontend HTML/JS/CSS |
| Price class | PriceClass_100 | US, Canada, Europe edge locations |
| HTTPS | Redirect HTTP to HTTPS | Enforced at CloudFront level |
| WAF | AWS WAF (optional) | Rate limiting, SQL injection protection |

---

## CI/CD Pipeline Flow

```
Developer pushes code to GitHub
         │
         ▼
Jenkins Pipeline (running on EC2 or EKS pod)
         │
         ├── 1. Checkout source code
         ├── 2. Detect which service changed (path filter)
         ├── 3. docker build -t <service>:<git-sha>
         ├── 4. Trivy image vulnerability scan
         ├── 5. docker push to ECR
         ├── 6. Update image tag in GitOps repo (helm/values-aws.yaml)
         └── 7. Notify Slack / email
                  │
                  ▼
         GitOps Repository (separate GitHub repo)
         helm/streamingapp/values-aws.yaml
         image.tag: <new-git-sha>
                  │
                  ▼
         ArgoCD (running in EKS)
         Watches GitOps repo every 3 minutes
                  │
                  ▼
         Detects values.yaml change
         Runs: helm upgrade streamingapp
                  │
                  ▼
         EKS rolling update
         Old pods replaced one by one
         Zero downtime deployment
```

---

## Cost Estimate (Approximate — us-east-1)

| Component | Specification | Estimated Monthly Cost |
|---|---|---|
| EKS Cluster | Control plane | $73 |
| EC2 Worker Nodes | 2x t3.medium | $60 |
| EC2 Data Node (MongoDB) | 1x t3.medium | $30 |
| ALB | 1 load balancer | $20 |
| NAT Gateway | 2x (one per AZ) | $65 |
| ElastiCache Redis | 1x cache.t3.micro | $15 |
| S3 | 100GB storage + requests | $5 |
| CloudFront | 1TB transfer | $85 |
| ECR | 5 repos, 10GB storage | $1 |
| Route 53 | 1 hosted zone | $1 |
| ACM | SSL certificate | Free |
| CloudWatch | Logs + metrics | $20 |
| Secrets Manager | 5 secrets | $3 |
| **Total** | | **~$383/month** |

> Compared to using DocumentDB (2x db.r6g.large at ~$280/month), self-hosted MongoDB on a single t3.medium saves ~$245/month. The trade-off is that you manage backups, upgrades, and there is no automatic failover.

---

## Minikube vs AWS — Full Comparison

| Aspect | Minikube (Local) | AWS (Production) |
|---|---|---|
| Entry point | `http://localhost` via minikube tunnel | `https://streamingapp.online` via GoDaddy → Route 53 → CloudFront |
| Load balancer | nginx Ingress Controller | AWS ALB + Load Balancer Controller |
| TLS/HTTPS | None | ACM certificate, enforced at CloudFront |
| Container registry | Local Minikube Docker daemon | ECR private registry |
| Database | MongoDB StatefulSet + hostPath PV | MongoDB on EC2 in private data subnet (us-east-1a) |
| Storage | Minikube node disk | S3 with CloudFront CDN |
| Secrets | Kubernetes Secrets (base64 only) | AWS Secrets Manager + IRSA |
| Monitoring | None | CloudWatch + Container Insights |
| Scaling | Manual replica count | HPA + Cluster Autoscaler |
| High availability | Single node | Multi-AZ EKS nodes (MongoDB is single AZ) |
| Image pull | imagePullPolicy: Never (local) | ECR pull via IRSA |
| AWS credentials | In ConfigMap/Secret | IRSA — no credentials in pods |
| CDN | None | CloudFront global edge network |
| DNS | localhost | GoDaddy (registrar) → Route 53 (hosted zone) |
| Cost | Free (laptop resources) | ~$383/month |

---

## Folder Structure for AWS Implementation

```
StreamingApp-infra/              ← separate repository
  terraform/
    modules/
      VPC/                       ← VPC, subnets, IGW, NAT, route tables
      EKS/                       ← EKS cluster, node group, IRSA
      ecr/                       ← 5 ECR repositories
      mongodb/                   ← EC2 instance, EBS volume, security group
      s3/                        ← S3 bucket, bucket policy, CloudFront OAC
      cloudfront/                ← CloudFront distribution, ACM certificate
      secrets/                   ← Secrets Manager secrets
      elasticache/               ← Redis cluster (optional)
    envs/
      dev/
        main.tf
        variables.tf
        outputs.tf
        terraform.tfvars
      prod/
        main.tf
        variables.tf
        outputs.tf
        terraform.tfvars
  helm/
    streamingapp/
      Chart.yaml
      values.yaml                ← defaults
      values-dev.yaml            ← dev overrides (ECR URIs, replica counts)
      values-prod.yaml           ← prod overrides
      templates/
        namespace.yaml
        configmap.yaml
        serviceaccount.yaml      ← IRSA annotations
        auth/
        admin/
        streaming/
        chat/
        frontend/
        ingress.yaml             ← ALB annotations
  argocd/
    application-dev.yaml
    application-prod.yaml
  jenkins/
    Jenkinsfile
```

---

## Next Steps

1. **Terraform** — Create VPC, ECR, EKS modules (`terraform/`)
2. **Push images to ECR** — Tag and push all 5 service images
3. **Helm charts** — Templatize Kubernetes manifests with AWS-specific values
4. **ArgoCD** — Install on EKS, connect to GitOps repo
5. **Jenkins** — Configure pipeline with ECR push and GitOps repo update
6. **DNS** — Update GoDaddy nameservers to Route 53, point A record to CloudFront
7. **Smoke test** — Register, upload video, verify streaming and chat
