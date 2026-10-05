import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as config from 'aws-cdk-lib/aws-config';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';

export class SriSecurityControlsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: cdk.StackProps) {
    super(scope, id, props);

    const configPrincipal = new iam.ServicePrincipal('config.amazonaws.com');

    const bucket = new s3.Bucket(this, 'SriConfigBucket');
    bucket.addToResourcePolicy(
      new iam.PolicyStatement({
        principals: [configPrincipal],
        actions: ['s3:GetBucketAcl'],
        resources: [bucket.bucketArn],
      }),
    );
    bucket.addToResourcePolicy(
      new iam.PolicyStatement({
        principals: [configPrincipal],
        actions: ['s3:PutObject'],
        resources: [bucket.arnForObjects('*')],
      }),
    );

    const configRole = new iam.Role(this, 'SriConfigRole', {
      roleName: 'sri-config-role',
      assumedBy: configPrincipal,
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWS_ConfigRole')],
    });

    const recorder = new config.CfnConfigurationRecorder(this, 'SriConfigRecorder', {
      name: 'sri-config-recorder',
      roleArn: configRole.roleArn,
      recordingGroup: { allSupported: false, resourceTypes: ['AWS::EC2::SecurityGroup'] },
    });

    const channel = new config.CfnDeliveryChannel(this, 'SriConfigChannel', {
      name: 'sri-config-channel',
      s3BucketName: bucket.bucketName,
    });
    channel.node.addDependency(recorder, bucket.policy!);

    const ruleLambda = new lambda.Function(this, 'SriSgRuleLambda', {
      functionName: 'sri-sg-rule-lambda',
      runtime: lambda.Runtime.PYTHON_3_13,
      handler: 'sri_sg_check.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '..', 'assets', 'lambda')),
      timeout: cdk.Duration.seconds(30),
    });

    const sgScope = config.RuleScope.fromResources([config.ResourceType.EC2_SECURITY_GROUP]);

    const detective = new config.CustomRule(this, 'SriDetectiveRule', {
      configRuleName: 'sri-detective-rule',
      lambdaFunction: ruleLambda,
      configurationChanges: true,
      ruleScope: sgScope,
    });
    detective.node.addDependency(channel);

    const reactive = new config.CustomRule(this, 'SriReactiveRule', {
      configRuleName: 'sri-reactive-rule',
      lambdaFunction: ruleLambda,
      configurationChanges: true,
      ruleScope: sgScope,
      inputParameters: { restrictedPorts: '22,3389,9092,9093' },
    });
    reactive.node.addDependency(channel);

    const remediationRole = new iam.Role(this, 'SriRemediationRole', {
      roleName: 'sri-remediation-role',
      assumedBy: new iam.ServicePrincipal('ssm.amazonaws.com'),
      inlinePolicies: {
        'sri-remediation-policy': new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              actions: [
                'ec2:DescribeSecurityGroups',
                'ec2:RevokeSecurityGroupIngress',
                'ec2:GetManagedPrefixListEntries',
              ],
              resources: ['*'],
            }),
          ],
        }),
      },
    });

    new config.CfnRemediationConfiguration(this, 'SriRemediation', {
      configRuleName: reactive.configRuleName,
      targetType: 'SSM_DOCUMENT',
      targetId: 'AWSConfigRemediation-RemoveUnrestrictedSourceIngressRules',
      automatic: true,
      parameters: {
        SecurityGroupId: { ResourceValue: { Value: 'RESOURCE_ID' } },
        AutomationAssumeRole: { StaticValue: { Values: [remediationRole.roleArn] } },
      },
    });
  }
}
