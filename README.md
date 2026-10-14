# Kafka-iac 

Single-node Apache Kafka on EC2 (no MSK) with AWS Config security controls. Built with Terraform, CloudFormation and CDK. Lab setup, us-east-2.

## What gets created

- VPC `sri-vpc` with one public subnet
- EC2 `sri-kafka` running Kafka 4.3.1 (KRaft), port 9092 open to the VPC only
- Secrets Manager secret with the Kafka admin user and password (SASL/SCRAM login)
- S3 bucket `sri-kafka-<suffix>` with all public access blocked (Terraform only)
- AWS Config recorder, a Lambda `sri-sg-rule-lambda`, and conformance pack `sri-conformance-pack` (CloudFormation and CDK only) with:
  - `sri-detective-rule`: reports security groups open to the internet
  - `sri-reactive-rule`: removes internet-open rules on ports 22, 3389, 9092 and 9093

Deploy with one tool at a time. The account must not already have an AWS Config recorder.

Terraform does not create the Config controls. Its plan is checked by the OPA policies instead.

## Folders

- `terraform/` - Terraform code and `buildspec.yml` for CodeBuild
- `cloudformation/` - `kafka-cluster.yaml` and `security-controls.yaml`
- `cdk/` - CDK app with `SriKafkaStack` and `SriSecurityControlsStack`
- `codebuild/` - CodeBuild project, webhook and Terraform state bucket
- `opa/` - OPA policies that check the Terraform plan

## Terraform

State is in the S3 bucket `sri-kafka-tfstate-<account-id>` (created by `codebuild/`).

```bash
cd terraform
terraform init -backend-config="bucket=sri-kafka-tfstate-<account-id>"
terraform apply
```

## CloudFormation

```bash
cd cloudformation
aws cloudformation deploy --region us-east-2 --stack-name sri-kafka --template-file kafka-cluster.yaml --capabilities CAPABILITY_NAMED_IAM
aws cloudformation deploy --region us-east-2 --stack-name sri-security-controls --template-file security-controls.yaml --capabilities CAPABILITY_NAMED_IAM
```

## CDK

```bash
cd cdk
npm install
npx cdk bootstrap aws://<account-id>/us-east-2
npx cdk deploy --all
```

## CI/CD with CodeBuild

CodeBuild project `sri-kafka-deploy` runs `terraform/buildspec.yml` on every push to the `devops` branch: init, validate, plan, OPA policy check, then apply.

Setup:

```bash
aws secretsmanager create-secret --region us-east-2 --name sri-github-token --secret-string '<github-token>'
cd codebuild
terraform init
terraform apply
aws codebuild start-build --region us-east-2 --project-name sri-kafka-deploy
```

The GitHub token needs the `repo` and `admin:repo_hook` scopes. It is only used to create the webhook.

## OPA policies

The policies in `opa/` check the Terraform plan before apply. The build stops if:

- `s3_public.rego` - an `aws_s3_bucket_public_access_block` has any of its four settings off, or a bucket ACL is `public-read` or `public-read-write`
- `sg_ssh.rego` - an `aws_security_group` ingress rule opens port 22, or all traffic, to `0.0.0.0/0`

Run it locally:

```bash
cd terraform
terraform plan -out=tfplan
terraform show -json tfplan > tfplan.json
opa eval --fail-defined --format raw -d ../opa -i tfplan.json 'data.terraform.deny[msg]'
```

No output means the plan passed. Otherwise each violation is printed and the command exits with 1.

## Test Kafka

```bash
aws ssm start-session --region us-east-2 --target <instance-id>
sudo -i
BS=$(hostname -I | awk '{print $1}'):9092
CC=/opt/kafka/config/sri-client.properties
/opt/kafka/bin/kafka-topics.sh --bootstrap-server $BS --command-config $CC --create --topic demo
echo hello | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $BS --producer.config $CC --topic demo
/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BS --consumer.config $CC --topic demo --from-beginning --max-messages 1
```

## Test the controls

CloudFormation and CDK only. Open port 9092 to the internet. After a few minutes the reactive rule removes it.

```bash
SG=$(aws ec2 describe-security-groups --region us-east-2 --filters Name=group-name,Values=sri-kafka-sg --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress --region us-east-2 --group-id $SG --protocol tcp --port 9092 --cidr 0.0.0.0/0
aws configservice describe-conformance-pack-compliance --region us-east-2 --conformance-pack-name sri-conformance-pack
aws ec2 describe-security-group-rules --region us-east-2 --filters Name=group-id,Values=$SG
```

## Clean up

```bash
cd terraform && terraform destroy
cd cdk && npx cdk destroy --all
aws cloudformation delete-stack --region us-east-2 --stack-name sri-security-controls
aws cloudformation delete-stack --region us-east-2 --stack-name sri-kafka
```

CloudFormation and CDK keep the Config S3 bucket. Empty and delete it by hand.

## Notes

- Single node, no high availability
- Traffic on 9092 is not encrypted (`SASL_PLAINTEXT`)
- Kafka does not restart after a reboot
