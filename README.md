# Kafka-iac

A self-managed, single-node Apache Kafka cluster on one AWS EC2 instance (**no Amazon MSK**), built three ways:

| Directory | Tool | Entry point |
|---|---|---|
| [`cloudformation/`](cloudformation/) | AWS CloudFormation (YAML) | `kafka-cluster.yaml` |
| [`cdk/`](cdk/) | AWS CDK v2 (TypeScript) | `lib/kafka-cluster-stack.ts` |
| [`terraform/`](terraform/) | Terraform (AWS provider v6) | `kafka.tf` |

All three deploy the same architecture, so you can compare how each tool expresses it. For a short overview of the design, see [ARCHITECTURE.md](ARCHITECTURE.md).

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
- **Clients authenticate with SASL/SCRAM-SHA-512.** Each tool creates a secret in AWS Secrets Manager with a generated admin password. The instance reads it at boot with its IAM role, so the password is never in user data, templates, or outputs.
- **Security controls** (AWS Config rules, auto-remediation, conformance pack) come as a separate stack. See [Security controls](#security-controls).

The bootstrap script is the same in all three: `cdk/assets/bootstrap.sh`, `terraform/templates/bootstrap.sh.tftpl`, and inline in the CFN template. It:
1. reads the instance's private IP and region from instance metadata (IMDSv2)
2. installs Java and `jq`
3. downloads Kafka from the Apache CDN, falling back to `archive.apache.org`
4. reads the admin username and password from Secrets Manager
5. writes `/etc/kafka/server.properties` and `/etc/kafka/client.properties` (both mode 600)
6. formats storage and adds the admin's SCRAM credential (`kafka-storage.sh format --add-scram`)
7. starts `kafka.service`

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

# security controls (see "Security controls" below)
aws cloudformation deploy \
  --region us-east-2 \
  --stack-name kafka-cfn-security \
  --template-file security-controls.yaml \
  --capabilities CAPABILITY_IAM
```

### CDK

```bash
cd cdk
npm install
npx cdk bootstrap aws://<account-id>/us-east-2   # once per account/region
npx cdk deploy --all    # KafkaCdkStack + KafkaCdkSecurityControls
```

Settings live in `cdk.json` → `context`. You can override them on the command line, e.g. `npx cdk deploy --all -c instanceType=m7i.large -c heapSize=4g`.

### Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # optional
terraform init
terraform apply         # Kafka + security controls in one root module
```

## Verify

Kafka takes about 1–2 minutes after the instance is running to install and start.

```bash
# shell into the instance (instance ID is in the stack outputs)
aws ssm start-session --region us-east-2 --target <instance-id>

sudo -iu root
BS=$(hostname -I | awk '{print $1}'):9092
CC=/etc/kafka/client.properties   # SASL/SCRAM settings written at boot

# bootstrap log / service status
tail /var/log/cloud-init-output.log
systemctl status kafka

# KRaft quorum: expect LeaderId 1 and a single voter
/opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server $BS --command-config $CC describe --status

# create, produce, consume
/opt/kafka/bin/kafka-topics.sh --bootstrap-server $BS --command-config $CC --create --topic demo --partitions 3
echo "hello kafka" | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $BS --producer.config $CC --topic demo
/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BS --consumer.config $CC --topic demo --from-beginning --max-messages 1

# without credentials the broker rejects the connection
/opt/kafka/bin/kafka-topics.sh --bootstrap-server $BS --list   # hangs / times out
```

Clients elsewhere in the VPC get the credentials from Secrets Manager (secret ARN is in the stack outputs):

```bash
aws secretsmanager get-secret-value --region us-east-2 --secret-id <secret-arn> --query SecretString --output text
```

and connect with `security.protocol=SASL_PLAINTEXT` and `sasl.mechanism=SCRAM-SHA-512`.

## Security controls

Each tool also deploys a small set of account-level guardrails, in the style of AWS Control Tower detective and proactive controls:

| Control | Type | What it does |
|---|---|---|
| `sg-no-world-ingress` | Detective (custom Config rule) | Lambda flags any security group with an ingress rule open to `0.0.0.0/0` or `::/0`, on any port. Report only. |
| `sg-no-world-ingress-restricted-ports` | Reactive (custom Config rule + auto-remediation) | Same Lambda, limited to restricted ports (default `22,3389,9092,9093`). A non-compliant group triggers an SSM Automation document that revokes the offending ingress rules. |
| `<name>-sg-controls` | Conformance pack | Deploys both rules and the remediation as one unit, with one compliance score. |

The Lambda, the SSM Automation document, and the remediation IAM role live outside the pack, because a pack may only contain Config rules and remediation configurations. Their ARNs and names are rendered into the pack template at deploy time. Pack input parameters aren't used: with three or more of them, pack creation failed with `The specified AWS Lambda function must be in the same region as the AWS Config rule`.

| | CloudFormation | CDK | Terraform |
|---|---|---|---|
| Where | `security-controls.yaml` (separate stack) | `lib/security-controls-stack.ts` (stack `KafkaCdkSecurityControls`) | `security.tf` |
| Lambda | inline `ZipFile` | `assets/lambda/sg_world_ingress.py` | `lambda/sg_world_ingress.py` |
| SSM document | inline | `assets/revoke-world-ingress.yaml` | inline in `security.tf` |
| Pack template | inline `TemplateBody` (`Fn::Sub`) | `assets/conformance-pack.yaml` | inline in `security.tf` (heredoc) |
| Settings | `CreateConfigRecorder`, `RestrictedPorts`, `AutomaticRemediation` | `createConfigRecorder`, `restrictedPorts`, `automaticRemediation` | `create_config_recorder`, `restricted_ports`, `automatic_remediation` |

> **Warning: these controls apply to the whole account and region, not only the Kafka stack.** Once deployed, any security group in us-east-2 that opens a restricted port to the internet has that ingress rule **revoked automatically**, including groups owned by other projects. To only report, set automatic remediation to `false`.

**AWS Config recorder.** A conformance pack needs a running Config recorder, and an account allows only one per region. By default each tool creates one that records only `AWS::EC2::SecurityGroup`, to keep costs down. If Config is already on (for example in a Control Tower-managed account), turn recorder creation off. Otherwise the deploy fails with `MaxNumberOfConfigurationRecordersExceededException`.

Test the reactive control by opening the Kafka port to the internet. The rule flags it, and within a few minutes the remediation removes it:

```bash
SG=<kafka security group id>
aws ec2 authorize-security-group-ingress --region us-east-2 --group-id $SG --protocol tcp --port 9092 --cidr 0.0.0.0/0

aws configservice describe-compliance-by-config-rule --region us-east-2 \
  --query 'ComplianceByConfigRules[?starts_with(ConfigRuleName, `sg-no-world-ingress`)]'
aws configservice describe-remediation-execution-status --region us-east-2 \
  --config-rule-name <sg-no-world-ingress-restricted-ports-conformance-pack-... rule name>
aws ec2 describe-security-group-rules --region us-east-2 --filters Name=group-id,Values=$SG
```

Config rules inside a pack get a suffix (`...-conformance-pack-<id>`). `aws configservice describe-config-rules` lists the full names.

## Tear down

```bash
aws cloudformation delete-stack --region us-east-2 --stack-name kafka-cfn-security   # CloudFormation
aws cloudformation delete-stack --region us-east-2 --stack-name kafka-cfn
npx cdk destroy --all                                                                # CDK
terraform destroy                                                                    # Terraform
```

- The CloudFormation security stack keeps its Config S3 bucket on delete, so the delete doesn't fail on a non-empty bucket. Empty the bucket and delete it by hand. CDK and Terraform empty and delete the bucket for you.
- Deleted secrets stay recoverable for 7–30 days. Each deploy creates a secret with a new unique name, so redeploying doesn't collide with one that is pending deletion.

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
- **Authenticated, but not encrypted.** The client listener is `SASL_PLAINTEXT`: clients must log in with SCRAM, but traffic isn't encrypted. For production, use `SASL_SSL` (TLS), enable an authorizer with ACLs, and set up per-client users.
- **No secret rotation.** The broker reads the admin secret only once, at first boot. Rotating the password means updating the SCRAM credential (`kafka-configs.sh --alter --add-config SCRAM-SHA-512=...`) and both properties files. A Secrets Manager rotation Lambda would have to do the same.
- **Data lives on the root volume.** Use a separate EBS data volume if data should survive instance replacement.
- **Not included:** monitoring (JMX exporter / CloudWatch agent), Schema Registry, and Kafka Connect.

## References

- [Apache Kafka documentation](https://kafka.apache.org/documentation/): KRaft, broker configs, operations
- [Kafka KRaft configuration](https://kafka.apache.org/documentation/#kraft_config)
- [AWS CloudFormation `AWS::EC2::Instance`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-instance.html)
- [AWS CDK v2 `aws-ec2` module](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_ec2-readme.html)
- [Terraform AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [AWS Config custom Lambda rules](https://docs.aws.amazon.com/config/latest/developerguide/evaluate-config_develop-rules_lambda-functions.html)
- [AWS Config conformance packs](https://docs.aws.amazon.com/config/latest/developerguide/conformance-packs.html)
- [Remediating noncompliant resources with AWS Config](https://docs.aws.amazon.com/config/latest/developerguide/remediation.html)
- [Kafka SASL/SCRAM](https://kafka.apache.org/documentation/#security_sasl_scram)
