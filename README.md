# Kafka-iac

Single-node Apache Kafka on EC2 (no MSK) with AWS Config security controls, written three times: CloudFormation, CDK and Terraform. This is a lab setup, not production.

| Folder | Tool |
|---|---|
| `cloudformation/` | CloudFormation (YAML) |
| `cdk/` | CDK v2 (TypeScript) |
| `terraform/` | Terraform (AWS provider 6.x) |

All three create the same resources with the same `sri-*` names, so deploy only one of them at a time. Design notes are in [ARCHITECTURE.md](ARCHITECTURE.md).

## What it creates

Kafka:
- Network: VPC `sri-vpc` (10.0.0.0/16) with one public subnet `sri-public-subnet` (10.0.1.0/24, us-east-2a), internet gateway `sri-igw` and route table `sri-public-rt`. The internet route is there so the instance can download Java and Kafka
- EC2 instance `sri-kafka` (c7i-flex.large, Amazon Linux 2023, `ami-08be4b1b8afa29958`) in that subnet
- Kafka 4.3.1 in KRaft mode, broker and controller in one process
- Security group `sri-kafka-sg`, port 9092 open to the VPC CIDR only
- A Secrets Manager secret with the admin user `sri-kafka-admin` and a generated password. The instance reads it at boot through its role `sri-kafka-role`, and clients log in with SASL/SCRAM-SHA-512
- No SSH key. Use SSM Session Manager to get a shell

Security controls:
- `sri-config-recorder`: AWS Config recorder for security groups, writing to an `sri-config-*` S3 bucket
- `sri-sg-rule-lambda`: Lambda that checks a security group for inbound rules from `0.0.0.0/0` or `::/0`
- `sri-conformance-pack`: conformance pack with:
  - `sri-detective-rule`: reports any security group that is open to the internet, on any port
  - `sri-reactive-rule`: flags security groups that open 22, 3389, 9092 or 9093 to the internet, and fixes them automatically. The fix runs the AWS runbook `AWSConfigRemediation-RemoveUnrestrictedSourceIngressRules` with the role `sri-remediation-role`. The runbook removes every internet-open inbound rule from that security group.

Secret name: Terraform names it `sri-kafka-secret` and generates the password with `random_password`. CloudFormation and CDK let Secrets Manager generate the password, and the secret name is generated (it starts with `SriKafkaSecret`). The ARN is always in the outputs.

Things to know before deploying:
- The controls apply to every security group in us-east-2, not just Kafka's. Use a lab account.
- An account can only have one Config recorder per region. If one already exists, the deploy fails.

## Prerequisites

- AWS CLI v2 with credentials for the lab account
- Terraform 1.10 or newer, or Node.js 18+ for CDK
- Session Manager plugin for the AWS CLI

## Deploy

Terraform:

The Terraform state is kept in the S3 bucket `sri-kafka-tfstate-<account-id>`, so the pipeline and your machine share it. That bucket is created by the `codebuild/` folder, so apply `codebuild/` once first (see [CI/CD with CodeBuild](#cicd-with-codebuild)).

```bash
cd terraform
terraform init -backend-config="bucket=sri-kafka-tfstate-<account-id>"
terraform apply
terraform output
```

CloudFormation:

```bash
cd cloudformation
aws cloudformation deploy --region us-east-2 --stack-name sri-kafka \
  --template-file kafka-cluster.yaml --capabilities CAPABILITY_NAMED_IAM
aws cloudformation deploy --region us-east-2 --stack-name sri-security-controls \
  --template-file security-controls.yaml --capabilities CAPABILITY_NAMED_IAM
aws cloudformation describe-stacks --region us-east-2 --stack-name sri-kafka --query 'Stacks[0].Outputs'
```

CDK:

```bash
aws sts get-caller-identity                        # check you are in the right account
cd cdk
npm install
npx cdk bootstrap aws://<account-id>/us-east-2     # once per account and region
npx cdk deploy --all                               # answer y to the IAM change prompts
```

`cdk bootstrap` only creates the `CDKToolkit` stack that CDK needs for its own assets. The project resources come from `cdk deploy --all`, which creates two stacks:

| Stack | What is in it |
|---|---|
| `SriKafkaStack` | `sri-vpc` with public subnet, internet gateway and route table, `sri-kafka-sg`, `sri-kafka-role` + instance profile, Kafka secret, EC2 `sri-kafka` |
| `SriSecurityControlsStack` | Config S3 bucket, `sri-config-role`, `sri-config-recorder` + delivery channel, `sri-sg-rule-lambda`, `sri-remediation-role`, `sri-conformance-pack` |

You can also deploy them one at a time with `npx cdk deploy SriKafkaStack` or `npx cdk deploy SriSecurityControlsStack`. After changing the code, run `npx cdk diff --all` to see what will change, then `npx cdk deploy --all` again.

To check that both stacks are up:

```bash
aws cloudformation describe-stacks --region us-east-2 \
  --query "Stacks[?starts_with(StackName,'Sri')].[StackName,StackStatus]" --output table
aws cloudformation describe-stacks --region us-east-2 --stack-name SriKafkaStack \
  --query 'Stacks[0].Outputs' --output table
```

The outputs (for all three tools) are the instance ID, the bootstrap server (`<private-ip>:9092`) and the secret ARN.

## Check Kafka

The instance needs a few minutes after launch to install Java, download Kafka and start it.

```bash
aws ssm start-session --region us-east-2 --target <instance-id>
```

On the instance:

```bash
sudo -i
tail -20 /var/log/cloud-init-output.log
tail -20 /opt/kafka/logs/server.log

BS=$(hostname -I | awk '{print $1}'):9092
CC=/opt/kafka/config/sri-client.properties

/opt/kafka/bin/kafka-topics.sh --bootstrap-server $BS --command-config $CC --create --topic demo
echo "hello" | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $BS --producer.config $CC --topic demo
/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BS --consumer.config $CC --topic demo --from-beginning --max-messages 1
```

Running `kafka-topics.sh --list` without `--command-config` should fail, which shows that the broker requires a login.

To read the credentials from your machine:

```bash
aws secretsmanager get-secret-value --region us-east-2 --secret-id <secret-arn> --query SecretString --output text
```

## Check the security controls

Make sure the pack deployed:

```bash
aws configservice describe-conformance-pack-status --region us-east-2 --conformance-pack-names sri-conformance-pack
```

Rules inside a conformance pack get a suffix on their names, so look up the full names first:

```bash
aws configservice describe-config-rules --region us-east-2 \
  --query "ConfigRules[?starts_with(ConfigRuleName, 'sri-')].ConfigRuleName" --output text
```

Now open the Kafka port to the internet and watch it get removed:

```bash
SG=$(aws ec2 describe-security-groups --region us-east-2 \
  --filters Name=group-name,Values=sri-kafka-sg --query 'SecurityGroups[0].GroupId' --output text)

aws ec2 authorize-security-group-ingress --region us-east-2 --group-id $SG \
  --protocol tcp --port 9092 --cidr 0.0.0.0/0
```

After a few minutes:

```bash
aws configservice describe-conformance-pack-compliance --region us-east-2 \
  --conformance-pack-name sri-conformance-pack

aws configservice describe-remediation-execution-status --region us-east-2 \
  --config-rule-name <full sri-reactive-rule name>

aws ec2 describe-security-group-rules --region us-east-2 --filters Name=group-id,Values=$SG
```

The `0.0.0.0/0` rule on 9092 should be gone, and the rule from the VPC CIDR should still be there.

Lambda logs are in CloudWatch under `/aws/lambda/sri-sg-rule-lambda`.

## CI/CD with CodeBuild

A CodeBuild project, `sri-kafka-deploy`, deploys the `terraform/` folder. It runs `terraform/buildspec.yml`, and a GitHub webhook starts it on every push to the `devops` branch.

`terraform/buildspec.yml` does this, in order:

1. Installs Terraform 1.16.0
2. `terraform init` with the S3 state bucket
3. `terraform fmt -check` and `terraform validate`
4. `terraform plan -out=tfplan`, then `terraform apply tfplan`
5. Reads the instance ID from `terraform output` and runs `terraform/verify-kafka.sh`, which waits for the instance and runs `kafka-topics.sh --list` on it over SSM with the SCRAM login

If any step fails, the build fails. There is no manual approval: a push to `devops` goes straight to apply.

The `codebuild/` folder is a small, separate Terraform project that creates the build setup:

| Resource | Name |
|---|---|
| CodeBuild GitHub credential | your GitHub personal access token, read from the Secrets Manager secret `sri-github-token`, used to create the webhook |
| CodeBuild project | `sri-kafka-deploy` (source: this repo, branch `devops`, buildspec `terraform/buildspec.yml`) |
| Webhook | starts a build on push to `devops` |
| Terraform state bucket (versioned) | `sri-kafka-tfstate-<account-id>` |
| IAM role | `sri-codebuild-role` (AdministratorAccess, since Terraform creates VPC, EC2, IAM, Config and Lambda resources) |

### Setting it up

The repo is public, so CodeBuild clones it without a login. GitHub access is only needed to create the push webhook, and for that CodeBuild uses a GitHub personal access token.

1. Create the token. On GitHub: **Settings > Developer settings > Personal access tokens > Tokens (classic) > Generate new token**, with the scopes `repo` and `admin:repo_hook`. Copy it.

2. Store it in Secrets Manager as a plain string, once:

   ```bash
   aws secretsmanager create-secret --region us-east-2 --name sri-github-token \
     --secret-string '<your-token>'
   ```

   To change it later:

   ```bash
   aws secretsmanager put-secret-value --region us-east-2 --secret-id sri-github-token \
     --secret-string '<new-token>'
   ```

   Then run `terraform apply` in `codebuild/` again so CodeBuild picks up the new token.

3. Create the CodeBuild setup. Terraform reads the token from the secret:

   ```bash
   cd codebuild
   terraform init
   terraform apply
   ```

   The token also ends up in Terraform's local state file (`codebuild/terraform.tfstate`), which is git-ignored. Don't share that file.

4. Start the first build, or just push to `devops`:

   ```bash
   aws codebuild start-build --region us-east-2 --project-name sri-kafka-deploy
   ```

An account can only have one CodeBuild credential for GitHub per region. If CodeBuild was already connected to GitHub in this account, the apply replaces that credential with your token.

If you already deployed `terraform/` with local state, move it to S3 before the first build, or the build will try to create everything again:

```bash
cd terraform
terraform init -migrate-state -backend-config="bucket=sri-kafka-tfstate-<account-id>"
```

### Watching a build

```bash
aws codebuild list-builds-for-project --region us-east-2 --project-name sri-kafka-deploy --max-items 1
aws codebuild batch-get-builds --region us-east-2 --ids <build-id> \
  --query 'builds[0].[buildStatus,currentPhase]' --output text
```

The full log is in the CodeBuild console under `sri-kafka-deploy`, and in CloudWatch Logs under `/aws/codebuild/sri-kafka-deploy`.

### Removing it

Destroy Kafka first, while the state bucket still exists, then the CodeBuild setup:

```bash
cd terraform && terraform destroy
cd ../codebuild && terraform destroy
```

The state bucket is versioned and not force-deleted, so the second destroy stops at it. Empty the bucket (all versions) in the S3 console, then run `terraform destroy` again.

## Tear down

Use the tool you deployed with:

```bash
cd terraform && terraform destroy

cd cdk && npx cdk destroy --all

aws cloudformation delete-stack --region us-east-2 --stack-name sri-security-controls
aws cloudformation delete-stack --region us-east-2 --stack-name sri-kafka
```

Terraform deletes the Config S3 bucket. CloudFormation and CDK keep it, because Config has written files to it. Empty it and delete it from the S3 console.

`cdk destroy` leaves the `CDKToolkit` bootstrap stack in place. Keep it if you will deploy with CDK again; otherwise delete it from the CloudFormation console.

In CloudFormation and CDK, the deleted secret stays recoverable for 7 days. Terraform deletes it immediately.

## Lab limitations

- One node, so no high availability and only one copy of the data.
- The listener is `SASL_PLAINTEXT`: clients have to log in, but traffic is not encrypted.
- The secret is not rotated.
- Kafka is started once by the user data script, not as a systemd service, so it does not come back after a reboot.
- Kafka runs as root and stores data on the root volume.
