#!/bin/bash
# Installs and starts one Apache Kafka node in KRaft mode (combined broker + controller).
# Placeholders (__NAME__) are replaced by the CDK stack before the script is used as user data.
set -euxo pipefail

KAFKA_VERSION="__KAFKA_VERSION__"
SCALA_VERSION="2.13"
NODE_ID="__NODE_ID__"
CLUSTER_ID="__CLUSTER_ID__"
QUORUM_VOTERS="__QUORUM_VOTERS__"
ADVERTISED_HOST="__ADVERTISED_HOST__"
HEAP_SIZE="__HEAP_SIZE__"

KAFKA_DIST="kafka_$SCALA_VERSION-$KAFKA_VERSION"

# Kafka 4.x brokers require Java 17+
dnf install -y java-21-amazon-corretto-headless shadow-utils tar gzip

id kafka >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin kafka

# dlcdn.apache.org is fast but only hosts current releases; archive.apache.org has every release but is slow.
curl -fsSL --retry 5 -o "/tmp/$KAFKA_DIST.tgz" "https://dlcdn.apache.org/kafka/$KAFKA_VERSION/$KAFKA_DIST.tgz" \
  || curl -fsSL --retry 5 -o "/tmp/$KAFKA_DIST.tgz" "https://archive.apache.org/dist/kafka/$KAFKA_VERSION/$KAFKA_DIST.tgz"
tar -xzf "/tmp/$KAFKA_DIST.tgz" -C /opt
rm -f "/tmp/$KAFKA_DIST.tgz"
ln -sfn "/opt/$KAFKA_DIST" /opt/kafka

mkdir -p /etc/kafka /var/lib/kafka/data /var/log/kafka

cat > /etc/kafka/server.properties <<EOF
process.roles=broker,controller
node.id=$NODE_ID
controller.quorum.voters=$QUORUM_VOTERS

listeners=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
advertised.listeners=PLAINTEXT://$ADVERTISED_HOST:9092
listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT

log.dirs=/var/lib/kafka/data
num.partitions=3
default.replication.factor=3
min.insync.replicas=2
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
auto.create.topics.enable=false
log.retention.hours=168
EOF

/opt/kafka/bin/kafka-storage.sh format --ignore-formatted \
  --cluster-id "$CLUSTER_ID" \
  --config /etc/kafka/server.properties

chown -R kafka:kafka "/opt/$KAFKA_DIST" /etc/kafka /var/lib/kafka /var/log/kafka

cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=Apache Kafka (KRaft)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kafka
Group=kafka
Environment="KAFKA_HEAP_OPTS=-Xms$HEAP_SIZE -Xmx$HEAP_SIZE"
Environment="LOG_DIR=/var/log/kafka"
ExecStart=/opt/kafka/bin/kafka-server-start.sh /etc/kafka/server.properties
ExecStop=/opt/kafka/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now kafka
