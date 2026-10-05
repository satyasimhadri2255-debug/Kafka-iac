# Architecture

Lab design: one Kafka node in the default VPC, plus two AWS Config rules that watch security groups. The same resources are written in CloudFormation, CDK and Terraform.

## Repo layout

```
Kafka-iac/
├── cloudformation/
│   ├── kafka-cluster.yaml        # Kafka: secret, SG, IAM role, EC2 (user data inline)
│   └── security-controls.yaml    # Config recorder, Lambda, detective + reactive rules
├── cdk/
│   ├── bin/kafka.ts              # app: SriKafkaStack + SriSecurityControlsStack
│   ├── lib/kafka-cluster-stack.ts
│   ├── lib/security-controls-stack.ts
│   └── assets/                   # bootstrap.sh, lambda/sri_sg_check.py
└── terraform/
    ├── versions.tf               # providers, region us-east-2
    ├── kafka.tf                  # default VPC lookup, SG, IAM role, EC2
    ├── secrets.tf                # generated password + secret + read permission
    ├── config_recorder.tf        # Config recorder + S3 bucket
    ├── detective_control.tf      # Lambda + sri-detective-rule
    ├── reactive_control.tf       # sri-reactive-rule + automatic remediation
    ├── outputs.tf
    ├── lambda/sri_sg_check.py
    └── templates/bootstrap.sh.tftpl
```

## Diagram

```
                       AWS us-east-2
┌──────────────────────────────────────────────────────────┐
│ Default VPC 172.31.0.0/16                                │
│   ┌──────────────────────────────────────────────┐       │
│   │ EC2 sri-kafka (c7i-flex.large, AL2023)       │       │
│   │ Kafka 4.3.1 KRaft, broker + controller       │       │
│   │ :9092 SASL/SCRAM (VPC only)                  │       │
│   │ role sri-kafka-role: SSM + read secret       │       │
│   └──────────────────────────────────────────────┘       │
│                                                          │
│ Secrets Manager: sri-kafka-secret (username/password)    │
│                                                          │
│ AWS Config: sri-config-recorder (security groups)        │
│   sri-detective-rule ──► sri-sg-rule-lambda ──► report   │
│   sri-reactive-rule  ──► sri-sg-rule-lambda ──► NON_COMPLIANT
│                              │                           │
│                              ▼                           │
│   AWSConfigRemediation-RemoveUnrestrictedSourceIngressRules
└──────────────────────────────────────────────────────────┘
```

## How the node boots

The user data script:
1. Installs Java 21 and `jq`
2. Downloads Kafka 4.3.1 to `/opt/kafka`
3. Reads the username and password from Secrets Manager
4. Writes `sri-server.properties` and `sri-client.properties` in `/opt/kafka/config`
5. Formats storage with a generated cluster ID and the admin's SCRAM credential
6. Starts Kafka

## How the controls work

1. A security group is created or changed, and the Config recorder records it.
2. Both rules call `sri-sg-rule-lambda`, which checks every ingress rule for `0.0.0.0/0` or `::/0`.
3. `sri-detective-rule` reports any port open to the internet.
4. `sri-reactive-rule` passes `restrictedPorts=22,3389,9092,9093`, so it flags only those ports.
5. A non-compliant result on `sri-reactive-rule` starts the AWS-managed SSM runbook, which removes the ingress rules open to the internet from that security group.
