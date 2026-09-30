#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { KafkaClusterStack } from '../lib/kafka-cluster-stack';
import { SecurityControlsStack } from '../lib/security-controls-stack';

const app = new cdk.App();

// `-c key=value` on the command line always yields strings, so coerce booleans and lists.
const boolContext = (key: string): boolean => String(app.node.getContext(key)) === 'true';
const portsContext = (key: string): number[] => String(app.node.getContext(key)).split(',').map(Number);

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  // Fixed because the hardcoded AMI in the stack only exists in this region.
  region: 'us-east-2',
};

new KafkaClusterStack(app, 'KafkaCdkStack', {
  env,
  kafkaVersion: app.node.getContext('kafkaVersion'),
  instanceType: app.node.getContext('instanceType'),
  heapSize: app.node.getContext('heapSize'),
  volumeSizeGb: Number(app.node.getContext('volumeSizeGb')),
  clientCidrs: app.node.getContext('clientCidrs'),
  kafkaAdminUser: app.node.getContext('kafkaAdminUser'),
});

// Account/region-wide Config rules, remediation and conformance pack.
new SecurityControlsStack(app, 'KafkaCdkSecurityControls', {
  env,
  createConfigRecorder: boolContext('createConfigRecorder'),
  restrictedPorts: portsContext('restrictedPorts'),
  automaticRemediation: boolContext('automaticRemediation'),
});
