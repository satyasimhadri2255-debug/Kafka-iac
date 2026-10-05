#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { SriKafkaStack } from '../lib/kafka-cluster-stack';
import { SriSecurityControlsStack } from '../lib/security-controls-stack';

const app = new cdk.App();

const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'us-east-2' };

new SriKafkaStack(app, 'SriKafkaStack', { env });
new SriSecurityControlsStack(app, 'SriSecurityControlsStack', { env });
