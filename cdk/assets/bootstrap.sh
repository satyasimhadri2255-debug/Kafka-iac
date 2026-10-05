#!/bin/bash
set -e

dnf install -y java-21-amazon-corretto-headless jq
curl -fsSL https://archive.apache.org/dist/kafka/4.3.1/kafka_2.13-4.3.1.tgz | tar -xz -C /opt
mv /opt/kafka_2.13-4.3.1 /opt/kafka

IP=$(hostname -I | awk '{print $1}')
SECRET=$(aws secretsmanager get-secret-value --region us-east-2 --secret-id "__SECRET_ARN__" --query SecretString --output text)
USERNAME=$(echo "$SECRET" | jq -r .username)
PASSWORD=$(echo "$SECRET" | jq -r .password)
JAAS="org.apache.kafka.common.security.scram.ScramLoginModule required username=\"$USERNAME\" password=\"$PASSWORD\";"

cat > /opt/kafka/config/sri-server.properties <<EOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@localhost:9093
listeners=SASL_PLAINTEXT://0.0.0.0:9092,CONTROLLER://localhost:9093
advertised.listeners=SASL_PLAINTEXT://$IP:9092
listener.security.protocol.map=SASL_PLAINTEXT:SASL_PLAINTEXT,CONTROLLER:PLAINTEXT
controller.listener.names=CONTROLLER
inter.broker.listener.name=SASL_PLAINTEXT
sasl.enabled.mechanisms=SCRAM-SHA-512
sasl.mechanism.inter.broker.protocol=SCRAM-SHA-512
listener.name.sasl_plaintext.scram-sha-512.sasl.jaas.config=$JAAS
log.dirs=/opt/kafka/data
offsets.topic.replication.factor=1
EOF

cat > /opt/kafka/config/sri-client.properties <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=$JAAS
EOF

/opt/kafka/bin/kafka-storage.sh format -t "$(/opt/kafka/bin/kafka-storage.sh random-uuid)" \
  -c /opt/kafka/config/sri-server.properties \
  --add-scram "SCRAM-SHA-512=[name=$USERNAME,password=$PASSWORD]"

/opt/kafka/bin/kafka-server-start.sh -daemon /opt/kafka/config/sri-server.properties
