# Architecture

This repo deploys **one self-managed Apache Kafka node on one EC2 instance** in AWS `us-east-2`. The same setup is written three times, once per IaC tool, so you can compare them side by side. Pick one tool and deploy only that one.

## Repo layout

```
Kafka-iac/
├── cloudformation/
│   ├── kafka-cluster.yaml          # Kafka stack, bootstrap script inline
│   └── security-controls.yaml      # Config rules, remediation, conformance pack
├── cdk/                            # AWS CDK v2, TypeScript
│   ├── bin/kafka.ts                # app entry, pins region us-east-2
│   ├── lib/kafka-cluster-stack.ts  # Kafka stack (VPC, SG, IAM, secret, EC2)
│   ├── lib/security-controls-stack.ts  # Config rules, remediation, conformance pack
│   ├── assets/                     # user data, rule Lambda, SSM doc, pack template
│   └── cdk.json                    # settings under "context"
└── terraform/
    ├── versions.tf                 # providers + region
    ├── variables.tf                # inputs
    ├── network.tf                  # VPC, subnet, IGW, route table
    ├── kafka.tf                    # SG, IAM role, EC2 instance
    ├── secrets.tf                  # Kafka admin secret + read permission
    ├── security.tf                 # Config recorder, rules, remediation, conformance pack
    ├── outputs.tf                  # bootstrap servers, instance ID, ...
    ├── lambda/sg_world_ingress.py  # custom Config rule
    └── templates/                  # user data, SSM doc, pack template
```

## What gets created

```
                     AWS us-east-2
┌─────────────────────────────────────────────────────┐
│ VPC 10.0.0.0/16                                     │
│                                                     │
│   Internet Gateway ◄── route 0.0.0.0/0              │
│          │                                          │
│ ┌────────┴────────────────────────────────────────┐ │
│ │ Public subnet 10.0.0.0/24                       │ │
│ │                                                 │ │
│ │  ┌───────────────────────────────────────────┐  │ │
│ │  │ EC2  c7i-flex.large  (Amazon Linux 2023)  │  │ │
│ │  │                                           │  │ │
│ │  │  Kafka 4.3.1, KRaft mode                  │  │ │
│ │  │  broker + controller in one process       │  │ │
│ │  │   :9092  clients     (open to VPC CIDR)   │  │ │
│ │  │   :9093  controller  (localhost only)     │  │ │
│ │  │                                           │  │ │
│ │  │  30 GiB encrypted gp3 root volume         │  │ │
│ │  └───────────────────────────────────────────┘  │ │
│ │     Security group: inbound 9092 only           │ │
│ │     IAM role: SSM core + read Kafka secret      │ │
│ └─────────────────────────────────────────────────┘ │
│                                                     │
│   Secrets Manager: kafka-admin (SCRAM user/pass)    │
│   AWS Config: SG rules + auto-remediation (pack)    │
└─────────────────────────────────────────────────────┘
          ▲
          │  admin shell via SSM Session Manager (no SSH)
       You / AWS CLI
```

| Component | Why it's there |
|---|---|
| VPC + public subnet | Isolated network for the node |
| Internet gateway | Lets the node download Java and Kafka without a NAT gateway |
| Security group | Only port 9092, only from the VPC CIDR (plus optional extra CIDRs) |
| IAM role + instance profile | Lets SSM Session Manager reach the instance, so port 22 stays closed, and lets the instance read the admin secret |
| Secrets Manager secret | Generated SASL/SCRAM admin password, read by the instance at boot |
| EC2 instance | Runs Kafka as a `systemd` service under a `kafka` user |
| Config rules + conformance pack | Flag security groups open to the internet, and revoke world-open ingress on restricted ports |

## How the node boots

Each tool passes the same script as EC2 user data. On first boot it:

1. Reads the instance's private IP and region from instance metadata (IMDSv2)
2. Installs Amazon Corretto 21 and `jq`
3. Downloads Kafka from the Apache CDN, falling back to `archive.apache.org`
4. Reads the admin credentials from Secrets Manager (shell tracing off, so they stay out of logs)
5. Writes `/etc/kafka/server.properties` (single node: replication factor 1; SASL/SCRAM listener) and `/etc/kafka/client.properties`
6. Formats KRaft storage with the cluster ID and the admin's SCRAM credential
7. Starts `kafka.service`

Kafka is ready about 1–2 minutes after the instance starts.

## Same design, three tools

| Concern | CloudFormation | CDK | Terraform |
|---|---|---|---|
| Settings | `Parameters` | `cdk.json` context | `variables.tf` / `terraform.tfvars` |
| Network | explicit VPC, IGW, subnet, routes | `ec2.Vpc` construct | `network.tf` |
| Bootstrap script | inline in template | `assets/bootstrap.sh` | `templates/bootstrap.sh.tftpl` |
| Cluster ID | passed in as parameter | generated in stack | `random_id` resource |
| Region lock | `RegionIsUsEast2` rule | `env.region` in `bin/kafka.ts` | provider `region` |

The region is locked because the AMI ID (`ami-08be4b1b8afa29958`) is hardcoded and only exists in `us-east-2`.

## Limitations

This is a dev/learning setup, not production:

- **Single node:** no high availability and only one copy of the data.
- **No TLS:** clients authenticate with SASL/SCRAM, but traffic on port 9092 isn't encrypted.
- **Account-wide controls:** the Config rules and auto-remediation apply to every security group in the region.
- **Data on root volume:** replacing the instance (for example, changing the AMI) loses all data.
- **No monitoring,** Schema Registry, or Kafka Connect.

See [README.md](README.md) for deploy, verify, and tear-down commands.
