# Architecture

One Kafka node in the default VPC, a secret for its login, and two AWS Config rules in a conformance pack that watch security groups. CloudFormation, CDK and Terraform each build the same thing.

## Files

```
Kafka-iac/
├── cloudformation/
│   ├── kafka-cluster.yaml          secret, security group, IAM role, EC2 (user data inline)
│   └── security-controls.yaml      Config recorder, S3 bucket, Lambda, remediation role, conformance pack
├── cdk/
│   ├── bin/kafka.ts                creates SriKafkaStack and SriSecurityControlsStack
│   ├── lib/kafka-cluster-stack.ts
│   ├── lib/security-controls-stack.ts
│   ├── assets/bootstrap.sh
│   ├── assets/lambda/sri_sg_check.py
│   └── cdk.context.json            cached default VPC lookup
└── terraform/
    ├── versions.tf                 providers, region us-east-2
    ├── kafka.tf                    default VPC lookup, security group, IAM role, EC2
    ├── secrets.tf                  password, secret, permission to read it
    ├── config_recorder.tf          Config recorder, S3 bucket, recorder role
    ├── detective_control.tf        rule Lambda, its role, invoke permission
    ├── reactive_control.tf         remediation role
    ├── conformance_pack.tf         sri-conformance-pack (both rules + remediation)
    ├── outputs.tf
    ├── lambda/sri_sg_check.py
    └── templates/bootstrap.sh.tftpl
```

The bootstrap script and the Lambda code are the same in all three tools. CloudFormation has them inline in the templates.

## Diagram

```
us-east-2
│
├── Default VPC (172.31.0.0/16)
│     └── EC2 sri-kafka
│           Kafka 4.3.1, KRaft, broker + controller
│           port 9092, SASL/SCRAM, VPC only
│           role sri-kafka-role (SSM + read secret)
│
├── Secrets Manager
│     └── sri-kafka-admin / generated password
│
└── AWS Config
      ├── sri-config-recorder (security groups only) → S3 bucket
      └── sri-conformance-pack
            ├── sri-detective-rule → sri-sg-rule-lambda → report
            └── sri-reactive-rule  → sri-sg-rule-lambda → NON_COMPLIANT
                                                           ↓
                       AWSConfigRemediation-RemoveUnrestrictedSourceIngressRules
```

## Boot sequence

The user data script runs once when the instance first starts:

1. Installs Java 21 and `jq`
2. Downloads Kafka 4.3.1 from archive.apache.org into `/opt/kafka`
3. Reads the username and password from Secrets Manager with the instance role
4. Writes `/opt/kafka/config/sri-server.properties` and `/opt/kafka/config/sri-client.properties`
5. Formats the storage with a new cluster ID and adds the SCRAM user
6. Starts Kafka in the background

Only the secret ARN is passed in through user data. The password itself never appears in user data, templates or outputs.

## How the controls work

1. A security group is created or changed, and the Config recorder picks it up.
2. Config calls `sri-sg-rule-lambda` once for each rule.
3. For `sri-detective-rule`, the Lambda marks the group NON_COMPLIANT if any inbound rule allows `0.0.0.0/0` or `::/0`. This rule only reports.
4. For `sri-reactive-rule`, the rule passes `restrictedPorts=22,3389,9092,9093`, so the Lambda only flags groups that open one of those ports.
5. When `sri-reactive-rule` marks a group NON_COMPLIANT, Config runs the AWS runbook with `sri-remediation-role`, up to 3 attempts, 60 seconds apart. The runbook removes the internet-open inbound rules from the group.
6. The group changes again, Config re-evaluates it, and it comes back COMPLIANT.

## Why it is built this way

- Default VPC instead of a custom one, to keep the lab small.
- One Lambda for both rules. The rules differ only in the `restrictedPorts` parameter.
- The detective rule only reports, because some internet-open ports (like 443 on a load balancer) are fine. The reactive rule only fixes ports that should never be public.
- The pack's values (Lambda ARN, role ARN) are written straight into the pack template. Pack input parameters are not used, because with three or more of them pack creation failed with "The specified AWS Lambda function must be in the same region as the AWS Config rule".
- The Config recorder only records security groups, which keeps the Config cost low.
