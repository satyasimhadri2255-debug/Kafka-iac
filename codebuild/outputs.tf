output "sri_codebuild_project" {
  value = aws_codebuild_project.sri_kafka_deploy.name
}

output "sri_tfstate_bucket" {
  value = aws_s3_bucket.sri_tfstate.bucket
}
