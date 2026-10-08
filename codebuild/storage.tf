data "aws_caller_identity" "sri_account" {}

resource "aws_s3_bucket" "sri_tfstate" {
  bucket = "sri-kafka-tfstate-${data.aws_caller_identity.sri_account.account_id}"
}

resource "aws_s3_bucket_versioning" "sri_tfstate_versioning" {
  bucket = aws_s3_bucket.sri_tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}
