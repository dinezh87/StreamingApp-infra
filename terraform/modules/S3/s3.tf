# ── S3 Bucket ─────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "media" {
  bucket = var.bucket_name
  tags   = { Name = var.bucket_name }
}

# ── Block all public access ───────────────────────────────────────────────────
# Objects are never directly reachable from the internet.
# All access goes through CloudFront (OAC) or IRSA roles.
resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Versioning ────────────────────────────────────────────────────────────────
# Keeps previous versions of every object. Protects against accidental deletes
# and overwrites — you can restore any prior version of a video or thumbnail.
resource "aws_s3_bucket_versioning" "media" {
  bucket = aws_s3_bucket.media.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ── Server-side encryption ────────────────────────────────────────────────────
# All objects are encrypted at rest using AES-256 (SSE-S3).
# No extra cost — AWS manages the keys automatically.
resource "aws_s3_bucket_encryption" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── CORS — allows the browser to upload directly via presigned URL ─────────────
# When an admin uploads a video, the browser POSTs directly to S3 using a
# presigned URL returned by the admin pod. Without CORS, the browser blocks
# the cross-origin request.
resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["https://${var.domain}"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# ── CloudFront Origin Access Control ─────────────────────────────────────────
# OAC is the modern replacement for OAI. It allows CloudFront to sign requests
# to S3 using SigV4, so S3 can verify the request came from YOUR CloudFront
# distribution and not from anyone else.
resource "aws_cloudfront_origin_access_control" "media" {
  name                              = "${var.bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── Bucket Policy ─────────────────────────────────────────────────────────────
# Grants read access to CloudFront OAC, read access to the streaming IRSA role,
# and write access to the admin IRSA role.
# Everything else is denied by the public access block above.
resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.media.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudFront OAC — read any object (serves videos and thumbnails to users)
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.media.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = var.cloudfront_distribution_arn
          }
        }
      },
      {
        # Streaming pod IRSA role — read videos and thumbnails for range requests
        Sid       = "AllowStreamingIRSA"
        Effect    = "Allow"
        Principal = { AWS = var.streaming_irsa_role_arn }
        Action    = ["s3:GetObject"]
        Resource  = "${aws_s3_bucket.media.arn}/*"
      },
      {
        # Admin pod IRSA role — upload and delete videos and thumbnails
        Sid       = "AllowAdminIRSA"
        Effect    = "Allow"
        Principal = { AWS = var.admin_irsa_role_arn }
        Action    = ["s3:PutObject", "s3:DeleteObject"]
        Resource  = "${aws_s3_bucket.media.arn}/*"
      }
    ]
  })
}
