# Kafka-iac

A self-managed Apache Kafka cluster on AWS EC2 (**no Amazon MSK**), built three ways:

| Directory | Tool | Entry point |
|---|---|---|
| [`cloudformation/`](cloudformation/) | AWS CloudFormation (YAML) | `kafka-cluster.yaml` |
| [`cdk/`](cdk/) | AWS CDK v2 (TypeScript) | `lib/kafka-cluster-stack.ts` |
| [`terraform/`](terraform/) | Terraform (AWS provider v6) | `kafka.tf` |

All three deploy the same architecture, so you can compare how each tool expresses it.

## Architecture

```
                         VPC 10.0.0.0/16
 ┌────────────────────────┬────────────────────────┬────────────────────────┐
 │ AZ a  10.0.0.0/24      │ AZ b  10.0.1.0/24      │ AZ c  10.0.2.0/24      │
 │ ┌────────────────────┐ │ ┌────────────────────┐ │ ┌────────────────────┐ │
 │ │ node 1  10.0.0.10  │ │ │ node 2  10.0.1.10  │ │ │ node 3  10.0.2.10  │ │
 │ │ broker+controller  │◄┼►│ broker+controller  │◄┼►│ broker+controller  │ │
 │ └────────────────────┘ │ └────────────────────┘ │ └────────────────────┘ │
 └────────────────────────┴────────────────────────┴────────────────────────┘
      :9092 clients (VPC CIDR)   :9093 KRaft quorum (brokers' SG only)
```

- **Kafka 4.3.1 in KRaft mode** (no ZooKeeper). Every node runs as both broker and controller (`process.roles=broker,controller`), so 3 EC2 instances form the whole cluster.
- **One node per AZ**, each with a **fixed private IP** (`x.x.N.10`). KRaft's static quorum (`controller.quorum.voters`) must be known before the nodes boot, and fixed IPs make it known.
- **Durability defaults:** replication factor 3, `min.insync.replicas=2`, and topic auto-creation off. The cluster keeps serving reads and `acks=all` writes with one node down.
- **Amazon Linux 2023** (`t3.medium`), Amazon Corretto 21, 1 GiB heap, 30 GiB encrypted gp3 root volume. Kafka runs as a systemd service under a `kafka` user.
- **Networking:** public subnets plus an internet gateway, so nodes can download Kafka without a NAT gateway (saves ~$100/month). The security group keeps Kafka private: 9092 is open only to the VPC CIDR (plus optional extra CIDRs), and 9093 only to the brokers themselves.
- **Access is through SSM Session Manager.** There are no SSH keys and port 22 is closed.

Bootstrap logic is the same in all three. The script (`cdk/assets/bootstrap.sh`, `terraform/templates/bootstrap.sh.tftpl`, and inline in the CFN template) does the following:
1. installs Java
2. downloads Kafka from the Apache CDN (falling back to `archive.apache.org`)
3. writes `/etc/kafka/server.properties`
4. formats storage with the shared cluster ID
5. starts `kafka.service`

## Prerequisites

- AWS CLI v2 with credentials (`aws sts get-caller-identity` works)
- A region with at least 3 AZs
- Terraform ≥ 1.5, or Node.js ≥ 18 for CDK
- [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for shell access

Deploy **only one** of the three at a time. They are independent stacks, and each creates its own VPC, so they don't conflict, but each costs money (about $0.13/hour for 3 × t3.medium plus EBS in us-east-1).

## Deploy

### CloudFormation

```bash
cd cloudformation
aws cloudformation deploy \
  --stack-name kafka-cfn \
  --template-file kafka-cluster.yaml \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides ClusterId=$(python3 -c "import uuid,base64;print(base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip('='))")
aws cloudformation describe-stacks --stack-name kafka-cfn --query 'Stacks[0].Outputs'
```

`CAPABILITY_AUTO_EXPAND` is needed because the template uses the `AWS::LanguageExtensions` transform (`Fn::ForEach` stamps out the 3 brokers).

### CDK

```bash
cd cdk
npm install
npx cdk bootstrap   # once per account/region
npx cdk deploy
```

Settings live in `cdk.json` → `context`. You can override them on the command line, e.g. `npx cdk deploy -c instanceType=m7i.large -c heapSize=4g`. The first synth writes `cdk.context.json`, which pins the AZs and AMI. Commit that file so later deploys don't replace brokers.

### Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # optional
terraform init
terraform apply
```

## Verify the cluster

Brokers take about 2–3 minutes after the instance is running to install and start Kafka.

```bash
# shell into any broker (instance IDs are in the stack outputs)
aws ssm start-session --target <instance-id>

sudo -iu root
BS=10.0.0.10:9092,10.0.1.10:9092,10.0.2.10:9092

# bootstrap log / service status
tail /var/log/cloud-init-output.log
systemctl status kafka

# KRaft quorum: expect a leader plus 3 voters
/opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server $BS describe --status

# create, produce, consume
/opt/kafka/bin/kafka-topics.sh --bootstrap-server $BS --create --topic demo --partitions 3 --replication-factor 3
/opt/kafka/bin/kafka-topics.sh --bootstrap-server $BS --describe --topic demo
echo "hello kafka" | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $BS --topic demo --command-property acks=all
/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BS --topic demo --from-beginning --max-messages 1
```

To test failover, run `sudo systemctl stop kafka` on one node, then produce and consume again. Both should keep working.

## Tear down

```bash
aws cloudformation delete-stack --stack-name kafka-cfn   # CloudFormation
npx cdk destroy                                          # CDK
terraform destroy                                        # Terraform
```

## Design notes and limitations

- **Plaintext listeners.** Traffic stays inside the VPC, but it isn't encrypted or authenticated. For production, add TLS and SASL/SCRAM or mTLS listeners and ACLs.
- **Data lives on the root volume.** If an instance is replaced, that node's data is lost, and it re-syncs from its replicas. For production, use a separate EBS data volume that outlives the instance.
- **The AMI is pinned** (Terraform `ignore_changes`, CDK `cachedInContext`) so a new AL2023 release doesn't replace brokers. CloudFormation re-resolves `LatestAmiId` on every update. On updates, pass the current AMI ID explicitly to avoid replacement. A replacement would also fail anyway, because the fixed IP is still in use.
- **The cluster ID must stay the same** for the life of a cluster:
  - Terraform: `random_id`, kept in state
  - CDK: derived from the account, region, and construct path
  - CloudFormation: the `ClusterId` parameter
- **Scaling:** Terraform and CDK accept any odd `broker_count`/`brokerCount` of 3 or more (the region needs that many AZs). The CloudFormation template is fixed at 3 nodes.
- **Not included:** monitoring (JMX exporter / CloudWatch agent), Schema Registry, Kafka Connect, and rolling-upgrade automation.

## References

- [Apache Kafka documentation](https://kafka.apache.org/documentation/): KRaft, broker configs, operations
- [Kafka KRaft configuration](https://kafka.apache.org/documentation/#kraft_config)
- [AWS CloudFormation `AWS::EC2::Instance`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-instance.html) and [`Fn::ForEach`](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/intrinsic-function-reference-foreach.html)
- [AWS CDK v2 `aws-ec2` module](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_ec2-readme.html)
- [Terraform AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
