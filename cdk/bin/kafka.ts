#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { KafkaClusterStack } from '../lib/kafka-cluster-stack';

const app = new cdk.App();

// A concrete account/region is required so the VPC can spread across 3 AZs
// (environment-agnostic stacks only see 2).
new KafkaClusterStack(app, 'KafkaCdkStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
  kafkaVersion: app.node.getContext('kafkaVersion'),
  instanceType: app.node.getContext('instanceType'),
  heapSize: app.node.getContext('heapSize'),
  volumeSizeGb: Number(app.node.getContext('volumeSizeGb')),
  brokerCount: Number(app.node.getContext('brokerCount')),
  clientCidrs: app.node.getContext('clientCidrs'),
});
