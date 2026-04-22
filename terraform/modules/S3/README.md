# S3 Module

## What is S3?

Amazon Simple Storage Service (S3) is object storage — it stores files (objects) identified by a key (path). Unlike a file system, there are no folders, just keys that look like paths (e.g. `videos/abc123.mp4`). S3 is used here to store all video files and thumbnail images uploaded by admins, and to serve them to users via CloudFront.

---

## What this module creates

### Resource overview

```
aws_s3_bucket                        ← the bucket itself
aws_s3_bucket_public_access_block    ← blocks ALL public access
aws_s3_bucket_versioning             ← keeps previous versions of objects
aws_s3_bucket_encryption             ← encrypts all objects at rest (AES-256)
aws_s3_bucket_cors_configuration     ← allows browser direct uploads via presigned URL
aws_cloudfront_origin_access_control ← OAC so CloudFront can read from the bucket
aws_s3_bucket_policy                 ← grants access to CloudFront OAC + IRSA roles only
```

---

### `aws_s3_bucket`

The bucket named `streamingapp-media`. S3 bucket names are **globally unique** across all AWS accounts — if the name is taken, Terraform will fail. The bucket stores:

```
streamingapp-media/
  videos/
    <video-id>.mp4
    <video-id>.webm
  thumbnails/
    <video-id>.jpg
```

---

### `aws_s3_bucket_public_access_block`

Four settings all set to `true`:

| Setting | What it blocks |
|---|---|
| `block_public_acls` | Prevents adding public ACLs to objects |
| `block_public_policy` | Prevents adding a bucket policy that grants public access |
| `ignore_public_acls` | Ignores any existing public ACLs |
| `restrict_public_buckets` | Blocks all anonymous access regardless of policy |

This is the most important security setting. Even if someone accidentally adds a public policy, this block overrides it. Users never access S3 directly — they always go through CloudFront.

---

### `aws_s3_bucket_versioning`

With versioning enabled, S3 keeps every version of every object. If a video is overwritten or deleted, the previous version is still recoverable. This protects against:
- Accidental deletion by the admin pod
- A bug in the upload code that corrupts a file
- A bad deployment that deletes objects

---

### `aws_s3_bucket_encryption` (SSE-S3)

All objects are encrypted at rest using AES-256. AWS manages the encryption keys automatically — there is no cost and no configuration needed beyond enabling it. This satisfies most compliance requirements for data at rest.

---

### `aws_s3_bucket_cors_configuration`

CORS (Cross-Origin Resource Sharing) is a browser security mechanism. When the admin uploads a video, the flow is:

```
1. Admin browser calls POST /api/admin/upload
   └─► admin pod generates a presigned S3 URL and returns it

2. Admin browser calls PUT <presigned-S3-URL> directly
   └─► This is a cross-origin request (browser is on streamingapp.online,
       S3 is on s3.amazonaws.com)
   └─► Without CORS, the browser blocks this request
   └─► With CORS, S3 tells the browser "requests from streamingapp.online are allowed"
```

The CORS rule allows `GET`, `PUT`, and `POST` from `https://streamingapp.online` only.

---

### `aws_cloudfront_origin_access_control` (OAC)

OAC is the mechanism that allows CloudFront to read objects from a private S3 bucket. It works by having CloudFront sign every request to S3 using AWS SigV4 — S3 then verifies the signature and checks the bucket policy to confirm the request came from your specific CloudFront distribution.

OAC replaced the older OAI (Origin Access Identity) approach. The key difference:
- OAI used a special IAM-like identity
- OAC uses SigV4 request signing — more secure and supports all S3 features including SSE-KMS

```
User browser
    │
    ▼
CloudFront edge (e.g. London)
    │  Signs request with SigV4 using OAC
    ▼
S3 bucket (us-east-1)
    │  Verifies signature + checks bucket policy
    ▼
Returns object (video or thumbnail)
```

---

### `aws_s3_bucket_policy`

Three statements in the policy:

| Statement | Principal | Action | Why |
|---|---|---|---|
| `AllowCloudFrontOAC` | CloudFront service | `s3:GetObject` | Serves videos and thumbnails to users via CDN |
| `AllowStreamingIRSA` | Streaming pod IAM role | `s3:GetObject` | Streaming pod fetches video bytes for range requests |
| `AllowAdminIRSA` | Admin pod IAM role | `s3:PutObject`, `s3:DeleteObject` | Admin pod uploads new videos and deletes old ones |

The `AllowCloudFrontOAC` statement uses a `Condition` on `AWS:SourceArn` — this means ONLY your specific CloudFront distribution can use OAC to read the bucket. Another CloudFront distribution (even in the same account) cannot.

---

## How the pieces connect

```
Admin uploads video
    │
    ├─► Admin pod → generates presigned URL → browser uploads directly to S3
    │                                         (CORS allows this)
    │
    └─► S3 stores video at videos/<id>.mp4

User watches video
    │
    ├─► CloudFront checks cache → miss → CloudFront signs request with OAC
    │                                    → S3 returns video → CloudFront caches it
    │
    └─► Next user → CloudFront serves from edge cache (S3 not hit again for 24h)

Streaming pod fetches video for range request
    │
    └─► Pod uses IRSA role → s3:GetObject → streams bytes to browser
```

---

## Inputs

| Variable | Type | Default | Description |
|---|---|---|---|
| `bucket_name` | string | `streamingapp-media` | Must be globally unique across all AWS accounts |
| `domain` | string | `streamingapp.online` | Used in CORS `allowed_origins` |
| `cloudfront_distribution_arn` | string | — | From CloudFront module — used in OAC bucket policy condition |
| `streaming_irsa_role_arn` | string | — | From IRSA setup — granted `s3:GetObject` |
| `admin_irsa_role_arn` | string | — | From IRSA setup — granted `s3:PutObject` and `s3:DeleteObject` |

> `cloudfront_distribution_arn`, `streaming_irsa_role_arn`, and `admin_irsa_role_arn` have no defaults because they must come from other modules. Terraform will error if they are not provided.

## Outputs

| Output | Used by |
|---|---|
| `bucket_name` | Helm `values-prod.yaml` — passed as `S3_BUCKET` env var to streaming and admin pods |
| `bucket_arn` | IRSA IAM policy — scopes the `s3:GetObject` / `s3:PutObject` permission to this bucket |
| `bucket_regional_domain_name` | CloudFront module — set as the S3 origin domain |
| `oac_id` | CloudFront module — attached to the S3 origin so CloudFront signs requests |

---

## Usage in envs/prod/main.tf

```hcl
module "s3" {
  source                      = "../../modules/S3"
  bucket_name                 = "streamingapp-media"
  domain                      = "streamingapp.online"
  cloudfront_distribution_arn = module.cloudfront.distribution_arn
  streaming_irsa_role_arn     = aws_iam_role.streaming_irsa.arn
  admin_irsa_role_arn         = aws_iam_role.admin_irsa.arn
}
```

> Note: The S3 module and CloudFront module have a circular dependency — S3 needs the CloudFront ARN for the bucket policy, and CloudFront needs the S3 domain for the origin. The way to break this is to apply the S3 bucket first (without the policy), then apply CloudFront, then apply the bucket policy. In practice this is handled by applying the full `main.tf` twice, or by using `depends_on` carefully.
