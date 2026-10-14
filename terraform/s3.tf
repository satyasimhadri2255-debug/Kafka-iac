resource "aws_s3_bucket" "sri_kafka_bucket" {
  bucket_prefix = "sri-kafka-"
  force_destroy = true

  tags = { Name = "sri-kafka-bucket" }
}

resource "aws_s3_bucket_public_access_block" "sri_kafka_bucket_pab" {
  bucket = aws_s3_bucket.sri_kafka_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = true
}
