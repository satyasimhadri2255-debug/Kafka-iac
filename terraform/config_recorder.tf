resource "aws_s3_bucket" "sri_config_bucket" {
  bucket_prefix = "sri-config-"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "sri_config_bucket_policy" {
  bucket = aws_s3_bucket.sri_config_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.sri_config_bucket.arn
      },
      {
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.sri_config_bucket.arn}/*"
      },
    ]
  })
}

resource "aws_iam_role" "sri_config_role" {
  name = "sri-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sri_config_policy" {
  role       = aws_iam_role.sri_config_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "sri_config_recorder" {
  name     = "sri-config-recorder"
  role_arn = aws_iam_role.sri_config_role.arn

  recording_group {
    all_supported  = false
    resource_types = ["AWS::EC2::SecurityGroup"]
  }
}

resource "aws_config_delivery_channel" "sri_config_channel" {
  name           = "sri-config-channel"
  s3_bucket_name = aws_s3_bucket.sri_config_bucket.bucket

  depends_on = [aws_config_configuration_recorder.sri_config_recorder, aws_s3_bucket_policy.sri_config_bucket_policy]
}

resource "aws_config_configuration_recorder_status" "sri_config_recorder_status" {
  name       = aws_config_configuration_recorder.sri_config_recorder.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.sri_config_channel]
}
