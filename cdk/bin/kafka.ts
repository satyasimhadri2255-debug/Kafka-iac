#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { KafkaClusterStack } from '../lib/kafka-cluster-stack';

const app = new cdk.App();

new KafkaClusterStack(app, 'KafkaCdkStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    // Fixed because the hardcoded AMI in the stack only exists in this region.
    region: 'us-east-2',
  },
  kafkaVersion: app.node.getContext('kafkaVersion'),
  instanceType: app.node.getContext('instanceType'),
  heapSize: app.node.getContext('heapSize'),
  volumeSizeGb: Number(app.node.getContext('volumeSizeGb')),
  clientCidrs: app.node.getContext('clientCidrs'),
});
