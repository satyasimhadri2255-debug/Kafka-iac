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
    channel.node.addDependency(bucket.policy!);

    const ruleLambda = new lambda.Function(this, 'SriSgRuleLambda', {
      functionName: 'sri-sg-rule-lambda',
      runtime: lambda.Runtime.PYTHON_3_13,
      handler: 'sri_sg_check.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '..', 'assets', 'lambda')),
      timeout: cdk.Duration.seconds(30),
    });

    ruleLambda.role!.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSConfigRulesExecutionRole'),
    );
    const invoke = new lambda.CfnPermission(this, 'SriConfigInvoke', {
      action: 'lambda:InvokeFunction',
      functionName: ruleLambda.functionName,
      principal: 'config.amazonaws.com',
    });

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

    const pack = new config.CfnConformancePack(this, 'SriConformancePack', {
      conformancePackName: 'sri-conformance-pack',
      templateBody: `
Resources:
  SriDetectiveRule:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: sri-detective-rule
      Scope:
        ComplianceResourceTypes:
          - AWS::EC2::SecurityGroup
      Source:
        Owner: CUSTOM_LAMBDA
        SourceIdentifier: ${ruleLambda.functionArn}
        SourceDetails:
          - EventSource: aws.config
            MessageType: ConfigurationItemChangeNotification
  SriReactiveRule:
    Type: AWS::Config::ConfigRule
    Properties:
      ConfigRuleName: sri-reactive-rule
      InputParameters:
        restrictedPorts: "22,3389,9092,9093"
      Scope:
        ComplianceResourceTypes:
          - AWS::EC2::SecurityGroup
      Source:
        Owner: CUSTOM_LAMBDA
        SourceIdentifier: ${ruleLambda.functionArn}
        SourceDetails:
          - EventSource: aws.config
            MessageType: ConfigurationItemChangeNotification
  SriRemediation:
    Type: AWS::Config::RemediationConfiguration
    DependsOn: SriReactiveRule
    Properties:
      ConfigRuleName: sri-reactive-rule
      TargetType: SSM_DOCUMENT
      TargetId: AWSConfigRemediation-RemoveUnrestrictedSourceIngressRules
      Automatic: true
      MaximumAutomaticAttempts: 3
      RetryAttemptSeconds: 60
      Parameters:
        SecurityGroupId:
          ResourceValue:
            Value: RESOURCE_ID
        AutomationAssumeRole:
          StaticValue:
            Values:
              - ${remediationRole.roleArn}
`,
    });
    pack.node.addDependency(recorder, channel, invoke);
  }
}
