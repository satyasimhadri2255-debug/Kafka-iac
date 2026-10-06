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
- EC2 instance `sri-kafka` (c7i-flex.large, Amazon Linux 2023, `ami-08be4b1b8afa29958`) in the default VPC in us-east-2
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
- The default VPC must exist in us-east-2.

## Prerequisites

- AWS CLI v2 with credentials for the lab account
- Terraform 1.5 or newer, or Node.js 18+ for CDK
- Session Manager plugin for the AWS CLI

## Deploy

Terraform:

```bash
cd terraform
terraform init
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
| `SriKafkaStack` | `sri-kafka-sg`, `sri-kafka-role` + instance profile, Kafka secret, EC2 `sri-kafka` |
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
