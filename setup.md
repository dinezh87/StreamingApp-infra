# StreamingApp — AWS Setup Guide

This guide walks you through deploying the StreamingApp microservices platform on AWS from scratch, following the production architecture defined in `ARCHITECTURE.md`. Steps are ordered so each one builds on the previous.

---

## Prerequisites

Install the following tools before starting:

```bash
# AWS CLI
brew install awscli
aws configure   # enter your Access Key, Secret, region: us-east-1, output: json

# Terraform
brew install terraform

# kubectl
brew install kubectl

# Helm
brew install helm

# eksctl (optional but useful for EKS debugging)
brew install eksctl

# Docker (for building and pushing images)
brew install --cask docker
```

Verify access:
```bash
aws sts get-caller-identity
```

---

## Step 1 — Delegate DNS from GoDaddy to Route 53

**Why:** The domain `streamingapp.online` is registered in GoDaddy. Route 53 will host the DNS zone so AWS can manage all records (ACM validation, CloudFront alias). You do NOT re-register the domain — you only change the nameservers in GoDaddy.

### 1a — Create a Hosted Zone in Route 53

1. Go to **AWS Console → Route 53 → Hosted Zones → Create Hosted Zone**
2. Domain name: `streamingapp.online`
3. Type: **Public hosted zone**
4. Click **Create**
5. Note the **4 NS records** Route 53 assigns (e.g. `ns-123.awsdns-45.com`)

### 1b — Update Nameservers in GoDaddy

1. Log in to **GoDaddy → My Products → streamingapp.online → DNS**
2. Click **Nameservers → Change → Enter my own nameservers**
3. Paste the 4 Route 53 NS records
4. Save — propagation takes 10–30 minutes

> After this, all DNS for `streamingapp.online` is managed in Route 53. GoDaddy is only the registrar.

---

## Step 2 — Request an ACM SSL Certificate

**Why:** CloudFront requires an ACM certificate in `us-east-1` for HTTPS. This must exist before creating the CloudFront distribution.

1. Go to **AWS Console → Certificate Manager → Request Certificate**
2. Choose **Request a public certificate**
3. Add domain names:
   - `streamingapp.online`
   - `*.streamingapp.online`
4. Choose **DNS validation** → click **Request**
5. Click **Create records in Route 53** — AWS automatically adds the CNAME validation records to your hosted zone
6. Wait ~2 minutes until status shows **Issued**
7. Note the **Certificate ARN** — used in Terraform for CloudFront and ALB

---

## Step 3 — Provision Infrastructure with Terraform

**Why:** Terraform creates all AWS resources (VPC, EKS, ECR, MongoDB EC2, S3, CloudFront, Secrets Manager, ElastiCache) in a repeatable, version-controlled way.

### 3a — Create the S3 backend for Terraform state

```bash
aws s3api create-bucket \
  --bucket streamingapp-terraform-state \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket streamingapp-terraform-state \
  --versioning-configuration Status=Enabled
```

### 3b — Folder structure

```
StreamingApp-infra/
  terraform/
    modules/
      VPC/
      EKS/
      ecr/
      mongodb/
      s3/
      cloudfront/
      secrets/
      elasticache/
    envs/
      prod/
        main.tf
        variables.tf
        terraform.tfvars
```

### 3c — VPC module

Creates: VPC `10.0.0.0/16`, 5 subnets (2 public, 2 private app, 1 private data), Internet Gateway, 2 NAT Gateways, and route tables.

```hcl
# terraform/envs/prod/main.tf (excerpt)
module "vpc" {
  source                   = "../../modules/VPC"
  vpc_cidr                 = "10.0.0.0/16"
  public_subnet_cidrs      = ["10.0.1.0/24", "10.0.2.0/24"]
  private_app_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
  private_data_subnet_cidr = "10.0.5.0/24"
}
```

### 3d — ECR module

Creates 5 private repositories — one per service:

```hcl
module "ecr" {
  source = "../../modules/ecr"
  repos  = ["auth", "streaming", "admin", "chat", "frontend"]
}
```

Enable image scanning on push in each repo to catch vulnerabilities automatically.

### 3e — EKS module

Creates the EKS control plane and a managed node group in the private app subnets:

```hcl
module "eks" {
  source                  = "../../modules/EKS"
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

The module also creates the OIDC provider for IRSA (IAM Roles for Service Accounts).

### 3f — MongoDB node group

The data node group is defined inside the EKS module. It places a single tainted node in the private data subnet. The MongoDB StatefulSet is deployed via Helm in Step 8 and uses a toleration + nodeSelector to land exclusively on this node.

The EBS CSI driver (installed in Step 5) provides the PersistentVolume backed by an EBS volume.

### 3g — S3 module

Creates the media bucket with versioning enabled and a bucket policy that allows access only from CloudFront OAC and the IRSA roles:

```hcl
module "s3" {
  source      = "../../modules/s3"
  bucket_name = "streamingapp-media"
  versioning  = true
}
```

Block all public access — objects are served exclusively through CloudFront.

### 3h — Secrets Manager module

Store all sensitive values so pods never hold long-lived credentials:

```hcl
module "secrets" {
  source = "../../modules/secrets"
  secrets = {
    "streamingapp/jwt_secret"    = var.jwt_secret
    "streamingapp/db_uri"        = "mongodb://<user>:<pass>@<mongodb-private-ip>:27017/streamingapp"
    "streamingapp/aws_s3_bucket" = "streamingapp-media"
  }
}
```

### 3i — ElastiCache Redis module

Creates a Redis cluster for Socket.IO multi-pod session sharing and JWT blacklisting:

```hcl
module "elasticache" {
  source        = "../../modules/elasticache"
  cluster_id    = "streamingapp-redis"
  node_type     = "cache.t3.micro"
  subnet_id     = module.vpc.private_data_subnet_id
  allowed_sg_id = module.eks.node_security_group_id
}
```

### 3j — CloudFront + ACM module

Creates the CloudFront distribution with two origins (S3 via OAC and ALB) and cache behaviours per path:

```hcl
module "cloudfront" {
  source       = "../../modules/cloudfront"
  acm_cert_arn = var.acm_certificate_arn   # from Step 2
  s3_bucket_id = module.s3.bucket_id
  alb_dns_name = module.eks.alb_dns_name   # filled after Step 6
  domain_name  = "streamingapp.online"
}
```

Cache behaviours:
| Path | TTL | Notes |
|---|---|---|
| `/videos/*` | 24h | Served from S3 via OAC |
| `/thumbnails/*` | 24h | Served from S3 via OAC |
| `/api/*` | 0 | No cache — forwarded to ALB |
| `/socket.io/*` | 0 | WebSocket enabled — forwarded to ALB |
| `/*` | 1h | Frontend HTML/JS/CSS from ALB |

### 3k — Apply Terraform

```bash
cd terraform/envs/prod
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Save the outputs — you'll need ECR URIs, EKS cluster name, MongoDB private IP, and Redis endpoint in later steps.

---

## Step 4 — Configure kubectl for EKS

**Why:** All Kubernetes operations (deploying pods, installing add-ons) require kubectl pointed at the EKS cluster.

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name streamingapp

kubectl get nodes   # should show 2 nodes in Ready state
```

---

## Step 5 — Install EKS Add-ons

**Why:** These add-ons provide the networking, storage, and load balancer capabilities the application depends on.

### AWS Load Balancer Controller

This controller watches Kubernetes Ingress resources and automatically creates/manages the ALB:

```bash
# Create IAM policy for the controller
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Install via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=streamingapp \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<LBC_IRSA_ROLE_ARN>
```

### EBS CSI Driver (via EKS managed add-on)

```bash
aws eks create-addon \
  --cluster-name streamingapp \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn <EBS_CSI_IRSA_ROLE_ARN>
```

### Cluster Autoscaler

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=streamingapp \
  --set awsRegion=us-east-1
```

---

## Step 6 — Create IRSA Roles

**Why:** IRSA (IAM Roles for Service Accounts) lets pods assume IAM roles without any AWS credentials stored in the cluster. Each service gets only the permissions it needs.

Create one IAM role per service and annotate the Kubernetes ServiceAccount:

| Service | IAM Permissions |
|---|---|
| `streaming` | `s3:GetObject` on `streamingapp-media/videos/*` and `thumbnails/*` |
| `admin` | `s3:PutObject`, `s3:DeleteObject` on `streamingapp-media/*` |
| `auth` | `secretsmanager:GetSecretValue` on `streamingapp/jwt_secret` |
| `chat` | `secretsmanager:GetSecretValue` on `streamingapp/jwt_secret` |
| All pods | `logs:PutLogEvents`, `logs:CreateLogStream` for CloudWatch |

Example trust policy for the streaming service IRSA role:
```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<OIDC_PROVIDER>"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "<OIDC_PROVIDER>:sub": "system:serviceaccount:streamingapp:streaming-sa"
    }
  }
}
```

---

## Step 7 — Build and Push Docker Images to ECR

**Why:** EKS pulls images from ECR. Each service needs to be containerised and pushed before deploying to the cluster.

```bash
# Authenticate Docker with ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

ECR_BASE=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/streamingapp
GIT_SHA=$(git rev-parse --short HEAD)

# Build and push each backend service
for SERVICE in auth streaming admin chat; do
  docker build -t $ECR_BASE/$SERVICE:$GIT_SHA ./backend/${SERVICE}Service
  docker push $ECR_BASE/$SERVICE:$GIT_SHA
done

# Frontend
docker build -t $ECR_BASE/frontend:$GIT_SHA ./frontend
docker push $ECR_BASE/frontend:$GIT_SHA
```

---

## Step 8 — Deploy with Helm

**Why:** Helm templates the Kubernetes manifests (Deployments, Services, Ingress, ConfigMaps, ServiceAccounts) and manages upgrades cleanly.

### 8a — Create the namespace

```bash
kubectl create namespace streamingapp
```

### 8b — Deploy MongoDB as a StatefulSet

MongoDB runs as a Kubernetes StatefulSet on the data node group. The toleration and nodeSelector ensure it only lands on the tainted data node:

```yaml
# helm/streamingapp/templates/mongodb/statefulset.yaml
spec:
  template:
    spec:
      tolerations:
        - key: "workload"
          value: "database"
          effect: "NoSchedule"
      nodeSelector:
        workload: database
      containers:
        - name: mongodb
          image: mongo:6
          volumeMounts:
            - name: data
              mountPath: /data/db
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        storageClassName: gp2
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 20Gi
```

### 8c — Create a Kubernetes Secret for MongoDB credentials

Pull the connection string from Secrets Manager and create a Kubernetes Secret:

```bash
DB_URI=$(aws secretsmanager get-secret-value \
  --secret-id streamingapp/db_uri \
  --query SecretString --output text)

kubectl create secret generic db-credentials \
  --from-literal=MONGO_URI="$DB_URI" \
  -n streamingapp
```

### 8c — Set Helm values for AWS

Create `helm/streamingapp/values-prod.yaml`:

```yaml
global:
  ecrBase: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/streamingapp
  imageTag: <GIT_SHA>
  region: us-east-1
  s3Bucket: streamingapp-media
  cdnUrl: https://streamingapp.online

auth:
  replicas: 2
  irsaRoleArn: <AUTH_IRSA_ROLE_ARN>

streaming:
  replicas: 2
  irsaRoleArn: <STREAMING_IRSA_ROLE_ARN>

admin:
  replicas: 1
  irsaRoleArn: <ADMIN_IRSA_ROLE_ARN>

chat:
  replicas: 2
  irsaRoleArn: <CHAT_IRSA_ROLE_ARN>
  redisUrl: redis://<ELASTICACHE_ENDPOINT>:6379

frontend:
  replicas: 2

ingress:
  certificateArn: <ACM_CERT_ARN>
  host: streamingapp.online
```

### 8d — Ingress manifest (ALB annotations)

```yaml
# helm/streamingapp/templates/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: streamingapp-ingress
  namespace: streamingapp
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: {{ .Values.ingress.certificateArn }}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
spec:
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /api/auth
            pathType: Prefix
            backend:
              service: { name: auth-service, port: { number: 3001 } }
          - path: /api/admin
            pathType: Prefix
            backend:
              service: { name: admin-service, port: { number: 3003 } }
          - path: /api/streaming
            pathType: Prefix
            backend:
              service: { name: streaming-service, port: { number: 3002 } }
          - path: /api/chat
            pathType: Prefix
            backend:
              service: { name: chat-service, port: { number: 3004 } }
          - path: /socket.io
            pathType: Prefix
            backend:
              service: { name: chat-service, port: { number: 3004 } }
          - path: /
            pathType: Prefix
            backend:
              service: { name: frontend-service, port: { number: 80 } }
```

### 8e — Install the Helm chart

```bash
helm upgrade --install streamingapp ./helm/streamingapp \
  -n streamingapp \
  -f helm/streamingapp/values-prod.yaml

kubectl get pods -n streamingapp   # all pods should reach Running state
```

After the Ingress is created, get the ALB DNS name:

```bash
kubectl get ingress -n streamingapp
# Note the ADDRESS column — this is the ALB DNS name
```

---

## Step 9 — Point Route 53 to CloudFront

**Why:** Users reach the app via `streamingapp.online`. Route 53 must resolve this to the CloudFront distribution, which then routes to S3 or the ALB.

1. Go to **Route 53 → Hosted Zones → streamingapp.online**
2. Create an **A record (Alias)**:
   - Record name: `streamingapp.online`
   - Alias target: your **CloudFront distribution domain** (e.g. `d1abc123.cloudfront.net`)
3. Create another **A record (Alias)** for `www.streamingapp.online` pointing to the same CloudFront distribution

> The ALB DNS name from Step 8e is used as the ALB origin inside CloudFront — it is NOT exposed directly to users.

---

## Step 10 — Install ArgoCD for GitOps

**Why:** ArgoCD watches the GitOps repository and automatically syncs Helm chart changes to EKS, enabling zero-downtime rolling deployments without manual `helm upgrade` commands.

```bash
kubectl create namespace argocd

helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd

# Get the initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

Create the ArgoCD Application pointing to your GitOps repo:

```yaml
# argocd/application-prod.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: streamingapp-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<your-org>/StreamingApp-infra
    targetRevision: main
    path: helm/streamingapp
    helm:
      valueFiles:
        - values-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: streamingapp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

```bash
kubectl apply -f argocd/application-prod.yaml
```

---

## Step 11 — Configure the Jenkins CI/CD Pipeline

**Why:** Jenkins automates the build → scan → push → deploy cycle on every code push, so deployments are consistent and auditable.

### 11a — Launch Jenkins on EC2

```bash
# Launch a t3.small EC2 in the public subnet (or run Jenkins as a pod in EKS)
# Install Jenkins, Docker, AWS CLI, and kubectl on the instance
```

### 11b — Configure Jenkins credentials

In Jenkins → Manage Credentials, add:
- AWS credentials (or use EC2 instance profile with ECR push permissions)
- GitHub token for checking out source and updating the GitOps repo

### 11c — Jenkinsfile

```groovy
pipeline {
  agent any
  environment {
    ECR_BASE = "<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/streamingapp"
    GIT_SHA  = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
  }
  stages {
    stage("Login to ECR") {
      steps {
        sh "aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_BASE"
      }
    }
    stage("Build & Scan") {
      steps {
        sh "docker build -t $ECR_BASE/${SERVICE}:$GIT_SHA ./backend/${SERVICE}Service"
        sh "trivy image --exit-code 1 --severity HIGH,CRITICAL $ECR_BASE/${SERVICE}:$GIT_SHA"
      }
    }
    stage("Push to ECR") {
      steps {
        sh "docker push $ECR_BASE/${SERVICE}:$GIT_SHA"
      }
    }
    stage("Update GitOps Repo") {
      steps {
        sh """
          git clone https://github.com/<your-org>/StreamingApp-infra gitops
          sed -i 's/imageTag:.*/imageTag: $GIT_SHA/' gitops/helm/streamingapp/values-prod.yaml
          cd gitops && git commit -am "ci: bump ${SERVICE} to $GIT_SHA" && git push
        """
      }
    }
  }
}
```

ArgoCD detects the `values-prod.yaml` change within 3 minutes and triggers a rolling update on EKS automatically.

---

## Step 12 — Configure CloudWatch Monitoring

**Why:** CloudWatch gives you centralised logs, metrics, and alarms across all pods and AWS services without running your own logging stack.

### Enable Container Insights

```bash
aws eks create-addon \
  --cluster-name streamingapp \
  --addon-name amazon-cloudwatch-observability
```

### Create alarms

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "streamingapp-high-cpu" \
  --metric-name pod_cpu_utilization \
  --namespace ContainerInsights \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --period 300 \
  --alarm-actions <SNS_TOPIC_ARN>
```

---

## Step 13 — Smoke Test

Verify the full stack end-to-end:

1. Open `https://streamingapp.online` — React app loads (CloudFront → ALB → frontend pod)
2. Register a new user account — (ALB → auth pod → MongoDB)
3. Log in as admin, open the Upload page, upload a small video and thumbnail — (ALB → admin pod → presigned S3 URL → S3 direct upload)
4. Browse to the video on the main page — thumbnail loads from CloudFront/S3 edge cache
5. Click Play — video streams (CloudFront → ALB → streaming pod → S3 range request)
6. Open the same video in two browser tabs — send a chat message in one tab and confirm it appears in the other (Socket.IO via ALB → chat pod → Redis pub/sub)

---

## Summary — Order of Operations

| Step | What | Why it must come first |
|---|---|---|
| 1 | GoDaddy → Route 53 NS delegation | Needed before ACM DNS validation can complete |
| 2 | ACM certificate | Needed before CloudFront and ALB HTTPS |
| 3 | Terraform (VPC → ECR → EKS → MongoDB → S3 → CF) | All infrastructure before any workloads |
| 4 | kubectl config | Needed before any `kubectl` or `helm` commands |
| 5 | EKS add-ons | Load Balancer Controller must exist before Ingress creates the ALB |
| 6 | IRSA roles | Must exist before pods start — pods assume roles at startup |
| 7 | Build & push images to ECR | Images must exist before Helm deploys pods |
| 8 | Helm deploy | Creates pods, Services, and the Ingress (which creates the ALB) |
| 9 | Route 53 → CloudFront | ALB DNS name must exist (from Step 8) to configure CloudFront origin |
| 10 | ArgoCD | Cluster must be running before ArgoCD can sync to it |
| 11 | Jenkins | Pipeline references ECR and GitOps repo — both must exist |
| 12 | CloudWatch | Add-on installed after EKS is stable |
| 13 | Smoke test | Validates the entire stack |
