# Kafka-iac

A self-managed, single-node Apache Kafka cluster on one AWS EC2 instance (**no Amazon MSK**), built three ways:

| Directory | Tool | Entry point |
|---|---|---|
| [`cloudformation/`](cloudformation/) | AWS CloudFormation (YAML) | `kafka-cluster.yaml` |
| [`cdk/`](cdk/) | AWS CDK v2 (TypeScript) | `lib/kafka-cluster-stack.ts` |
| [`terraform/`](terraform/) | Terraform (AWS provider v6) | `kafka.tf` |

All three deploy the same architecture, so you can compare how each tool expresses it.

## Architecture

```
              VPC 10.0.0.0/16  (us-east-2)
 ┌──────────────────────────────────────────────┐
 │ public subnet 10.0.0.0/24                    │
 │ ┌──────────────────────────────────────────┐ │
 │ │ EC2 (c7i-flex.large, AL2023)             │ │
 │ │ Kafka 4.3.1 — broker + KRaft controller  │ │
 │ │ :9092 clients   :9093 controller (local) │ │
 │ └──────────────────────────────────────────┘ │
 └──────────────────────────────────────────────┘
```

- **Kafka 4.3.1 in KRaft mode** (no ZooKeeper). One instance acts as both broker and controller (`process.roles=broker,controller`).
- **The AMI is hardcoded** to `ami-08be4b1b8afa29958`, Amazon Linux 2023 x86_64 in **us-east-2**. AMI IDs are region-specific, so each tool is locked to us-east-2:
  - Terraform: the provider `region`
  - CDK: the stack `env.region`
  - CloudFormation: a `Rules` assertion that rejects other regions
- **Single-node settings:** replication factor 1 and `min.insync.replicas=1`. There is only one copy of the data (see limitations).
- The instance runs Amazon Corretto 21 with a 1 GiB heap on a 30 GiB encrypted gp3 root volume. Kafka runs as a systemd service under a `kafka` user.
- **Networking:** a public subnet and an internet gateway, so the node can download Kafka without a NAT gateway. The security group opens only port 9092, and only to the VPC CIDR (plus optional extra CIDRs). The controller port 9093 listens on localhost only.
- **Access is through SSM Session Manager.** There are no SSH keys and port 22 is closed.

The bootstrap script is the same in all three: `cdk/assets/bootstrap.sh`, `terraform/templates/bootstrap.sh.tftpl`, and inline in the CFN template. It:
1. reads the instance's private IP from instance metadata (IMDSv2)
2. installs Java
3. downloads Kafka from the Apache CDN, falling back to `archive.apache.org`
4. writes `/etc/kafka/server.properties`
5. formats storage
6. starts `kafka.service`

## Prerequisites

- AWS CLI v2 with credentials (`aws sts get-caller-identity` works)
- Terraform ≥ 1.5, or Node.js ≥ 18 for CDK
- [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for shell access

Deploy **only one** of the three at a time. Each creates its own VPC. Default instance `c7i-flex.large` is Free Tier eligible (4 GiB RAM). On a Free Tier account only eligible types can launch: `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`.

## Deploy

### CloudFormation

```bash
cd cloudformation
aws cloudformation deploy \
  --region us-east-2 \
  --stack-name kafka-cfn \
  --template-file kafka-cluster.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides ClusterId=$(python3 -c "import uuid,base64;print(base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip('='))")
aws cloudformation describe-stacks --region us-east-2 --stack-name kafka-cfn --query 'Stacks[0].Outputs'
```

### CDK

```bash
cd cdk
npm install
npx cdk bootstrap aws://<account-id>/us-east-2   # once per account/region
npx cdk deploy
```

Settings live in `cdk.json` → `context`. You can override them on the command line, e.g. `npx cdk deploy -c instanceType=m7i.large -c heapSize=4g`.

### Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # optional
terraform init
terraform apply
```

## Verify

Kafka takes about 1–2 minutes after the instance is running to install and start.

```bash
# shell into the instance (instance ID is in the stack outputs)
aws ssm start-session --region us-east-2 --target <instance-id>

sudo -iu root
BS=$(hostname -I | awk '{print $1}'):9092

# bootstrap log / service status
tail /var/log/cloud-init-output.log
systemctl status kafka

# KRaft quorum: expect LeaderId 1 and a single voter
/opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server $BS describe --status

# create, produce, consume
/opt/kafka/bin/kafka-topics.sh --bootstrap-server $BS --create --topic demo --partitions 3
echo "hello kafka" | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $BS --topic demo
/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BS --topic demo --from-beginning --max-messages 1
```

## Tear down

```bash
aws cloudformation delete-stack --region us-east-2 --stack-name kafka-cfn   # CloudFormation
npx cdk destroy                                                             # CDK
terraform destroy                                                           # Terraform
```

## Changing the AMI or region

The AMI ID appears in one place per tool:
- `terraform/kafka.tf` (`ami`), plus `region` in `terraform/versions.tf`
- `cdk/lib/kafka-cluster-stack.ts` (`AMI_ID`, `AMI_REGION`), plus `region` in `cdk/bin/kafka.ts`
- `cloudformation/kafka-cluster.yaml` (`ImageId`), plus the `RegionIsUsEast2` rule

Look up the current Amazon Linux 2023 AMI for a region:

```bash
aws ssm get-parameter --region <region> \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text
```

Changing the AMI replaces the instance, and all Kafka data on it is lost.

## Design notes and limitations

- **Single node means no high availability.** If the instance or its disk fails, Kafka is down and the data may be lost. This setup is fine for dev, learning, and demos. Production needs 3 or more brokers across AZs.
- **Plaintext listener.** Traffic stays inside the VPC but isn't encrypted or authenticated. For production, add TLS and SASL/SCRAM or mTLS plus ACLs.
- **Data lives on the root volume.** Use a separate EBS data volume if data should survive instance replacement.
- **Not included:** monitoring (JMX exporter / CloudWatch agent), Schema Registry, and Kafka Connect.

## References

- [Apache Kafka documentation](https://kafka.apache.org/documentation/): KRaft, broker configs, operations
- [Kafka KRaft configuration](https://kafka.apache.org/documentation/#kraft_config)
- [AWS CloudFormation `AWS::EC2::Instance`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-instance.html)
- [AWS CDK v2 `aws-ec2` module](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_ec2-readme.html)
- [Terraform AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
