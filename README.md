# Kafka-iac

A lab setup: a self-managed, single-node Apache Kafka on one EC2 instance (**no Amazon MSK**), plus AWS Config security controls. It is built three ways:

| Directory | Tool |
|---|---|
| [`cloudformation/`](cloudformation/) | AWS CloudFormation (YAML) |
| [`cdk/`](cdk/) | AWS CDK v2 (TypeScript) |
| [`terraform/`](terraform/) | Terraform (AWS provider v6) |

All three deploy the same resources, named `sri-*`. Deploy only one at a time. See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## What gets deployed

**Kafka**
- One EC2 instance `sri-kafka` (`c7i-flex.large`, Amazon Linux 2023 `ami-08be4b1b8afa29958`) in the **default VPC** of **us-east-2**.
- Kafka 4.3.1 in KRaft mode: one process is both broker and controller.
- Security group `sri-kafka-sg`: port 9092 open only to the default VPC CIDR.
- Clients log in with SASL/SCRAM-SHA-512. The password is generated in Secrets Manager (`sri-kafka-secret`), and the instance reads it at boot with its IAM role (`sri-kafka-role`).
- Admin access is through SSM Session Manager. There is no SSH key.

**Security controls (AWS Config)**

| Resource | Purpose |
|---|---|
| `sri-config-recorder` + S3 bucket | Records security group changes (Config rules need a recorder) |
| `sri-sg-rule-lambda` | Custom rule logic: finds ingress open to `0.0.0.0/0` or `::/0` |
| `sri-detective-rule` | **Detective**: reports any security group open to the internet, on any port |
| `sri-reactive-rule` | **Reactive**: flags security groups that open ports 22, 3389, 9092 or 9093 to the internet |
| Remediation on `sri-reactive-rule` | Runs the AWS runbook `AWSConfigRemediation-RemoveUnrestrictedSourceIngressRules` automatically, which removes the ingress rules open to the internet (role `sri-remediation-role`) |

> **Warning:** the controls apply to every security group in us-east-2. Use a lab account. The account must not already have an AWS Config recorder, or the deploy fails.

## Prerequisites

- AWS CLI v2 with credentials
- Terraform ≥ 1.5, or Node.js ≥ 18 for CDK
- [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- A default VPC in us-east-2

## Deploy

### Terraform

```bash
cd terraform
terraform init
terraform apply
```

### CloudFormation

```bash
cd cloudformation
aws cloudformation deploy --region us-east-2 --stack-name sri-kafka \
  --template-file kafka-cluster.yaml --capabilities CAPABILITY_NAMED_IAM
aws cloudformation deploy --region us-east-2 --stack-name sri-security-controls \
  --template-file security-controls.yaml --capabilities CAPABILITY_NAMED_IAM
```

### CDK

```bash
cd cdk
npm install
npx cdk bootstrap aws://<account-id>/us-east-2
npx cdk deploy --all
```

## Verify Kafka

Kafka is ready about 1–2 minutes after the instance starts.

```bash
aws ssm start-session --region us-east-2 --target <instance-id>

sudo -i
BS=$(hostname -I | awk '{print $1}'):9092
CC=/opt/kafka/config/sri-client.properties

tail /opt/kafka/logs/server.log
/opt/kafka/bin/kafka-topics.sh --bootstrap-server $BS --command-config $CC --create --topic demo
echo "hello" | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $BS --producer.config $CC --topic demo
/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BS --consumer.config $CC --topic demo --from-beginning --max-messages 1
```

Get the credentials for other clients:

```bash
aws secretsmanager get-secret-value --region us-east-2 --secret-id <secret-arn> --query SecretString --output text
```

## Verify the controls

Open the Kafka port to the internet, then watch the reactive rule remove it within a few minutes:

```bash
SG=<sri-kafka-sg id>
aws ec2 authorize-security-group-ingress --region us-east-2 --group-id $SG --protocol tcp --port 9092 --cidr 0.0.0.0/0

aws configservice describe-compliance-by-config-rule --region us-east-2 --config-rule-names sri-detective-rule sri-reactive-rule
aws configservice describe-remediation-execution-status --region us-east-2 --config-rule-name sri-reactive-rule
aws ec2 describe-security-group-rules --region us-east-2 --filters Name=group-id,Values=$SG
```

## Tear down

```bash
terraform destroy
npx cdk destroy --all
aws cloudformation delete-stack --region us-east-2 --stack-name sri-security-controls
aws cloudformation delete-stack --region us-east-2 --stack-name sri-kafka
```

The CloudFormation Config bucket is kept on delete; empty and delete it by hand.

## Lab limitations

- Single node: no high availability, one copy of the data.
- `SASL_PLAINTEXT`: clients must log in, but traffic is not encrypted.
- No secret rotation.
- Data lives on the root volume.
- Kafka is started once by user data, not as a service, so it does not restart after a reboot.
