#!/bin/bash
set -euo pipefail

echo "Waiting for instance $INSTANCE_ID to pass status checks"
aws ec2 wait instance-status-ok --region us-east-2 --instance-ids "$INSTANCE_ID"

CHECK='for i in $(seq 1 30); do /opt/kafka/bin/kafka-topics.sh --bootstrap-server $(hostname -I | cut -d" " -f1):9092 --command-config /opt/kafka/config/sri-client.properties --list && exit 0; sleep 20; done; exit 1'
PARAMS=$(jq -n --arg c "$CHECK" '{commands: [$c]}')

for i in $(seq 1 20); do
  CMD_ID=$(aws ssm send-command --region us-east-2 --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
    --parameters "$PARAMS" --timeout-seconds 900 --query Command.CommandId --output text) && break
  echo "Instance not registered with SSM yet, retrying"
  sleep 15
done

STATUS=Pending
while [[ "$STATUS" == Pending || "$STATUS" == InProgress || "$STATUS" == Delayed ]]; do
  sleep 15
  STATUS=$(aws ssm get-command-invocation --region us-east-2 --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)
done

echo "Kafka check: $STATUS"
aws ssm get-command-invocation --region us-east-2 --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent,StandardErrorContent]' --output text
[ "$STATUS" = Success ]
