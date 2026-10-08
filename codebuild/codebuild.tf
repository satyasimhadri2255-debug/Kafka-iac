data "aws_secretsmanager_secret_version" "sri_github_token" {
  secret_id = "sri-github-token"
}

resource "aws_codebuild_source_credential" "sri_github" {
  auth_type   = "PERSONAL_ACCESS_TOKEN"
  server_type = "GITHUB"
  token       = data.aws_secretsmanager_secret_version.sri_github_token.secret_string
}

resource "aws_codebuild_project" "sri_kafka_deploy" {
  name          = "sri-kafka-deploy"
  service_role  = aws_iam_role.sri_codebuild_role.arn
  build_timeout = 60

  source {
    type            = "GITHUB"
    location        = "https://github.com/satyasimhadri2255-debug/Kafka-iac.git"
    git_clone_depth = 1
    buildspec       = "terraform/buildspec.yml"
  }

  source_version = "devops"

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "TF_STATE_BUCKET"
      value = aws_s3_bucket.sri_tfstate.bucket
    }
  }

  depends_on = [aws_codebuild_source_credential.sri_github]
}

resource "aws_codebuild_webhook" "sri_kafka_deploy" {
  project_name = aws_codebuild_project.sri_kafka_deploy.name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }

    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/devops$"
    }
  }
}
