import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as config from 'aws-cdk-lib/aws-config';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import * as yaml from 'yaml';

export interface SecurityControlsStackProps extends cdk.StackProps {
  /**
   * Create an AWS Config recorder and delivery channel. Set false if Config is already
   * recording in this account/region (e.g. Control Tower); only one recorder is allowed.
   */
  readonly createConfigRecorder: boolean;
  /** Ports that must never be open to 0.0.0.0/0 or ::/0. Matching rules are revoked. */
  readonly restrictedPorts: number[];
  /** Revoke world-open ingress on restrictedPorts automatically instead of only reporting. */
  readonly automaticRemediation: boolean;
}

const ASSETS = path.join(__dirname, '..', 'assets');

/**
 * A custom Config rule (detective), an auto-remediating Config rule (reactive), and a
 * conformance pack that deploys both. These are account/region-wide: they evaluate every
 * security group in the region, not only the Kafka one.
 */
export class SecurityControlsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: SecurityControlsStackProps) {
    super(scope, id, props);

    // Conformance packs need a running recorder.
    let recorderReady: Construct | undefined;
    if (props.createConfigRecorder) {
      const bucket = new s3.Bucket(this, 'ConfigBucket', {
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        encryption: s3.BucketEncryption.S3_MANAGED,
        enforceSSL: true,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
        autoDeleteObjects: true,
      });
      const configPrincipal = new iam.ServicePrincipal('config.amazonaws.com');
      const sourceAccount = { StringEquals: { 'AWS:SourceAccount': this.account } };
      bucket.addToResourcePolicy(
        new iam.PolicyStatement({
          principals: [configPrincipal],
          actions: ['s3:GetBucketAcl', 's3:ListBucket'],
          resources: [bucket.bucketArn],
          conditions: sourceAccount,
        }),
      );
      bucket.addToResourcePolicy(
        new iam.PolicyStatement({
          principals: [configPrincipal],
          actions: ['s3:PutObject'],
          resources: [bucket.arnForObjects(`AWSLogs/${this.account}/Config/*`)],
          conditions: {
            StringEquals: { 's3:x-amz-acl': 'bucket-owner-full-control', 'AWS:SourceAccount': this.account },
          },
        }),
      );

      const recorderRole = new iam.Role(this, 'ConfigRecorderRole', {
        assumedBy: configPrincipal,
        managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWS_ConfigRole')],
      });

      // Record only what the rules need, to keep Config costs down.
      const recorder = new config.CfnConfigurationRecorder(this, 'Recorder', {
        roleArn: recorderRole.roleArn,
        recordingGroup: { allSupported: false, resourceTypes: ['AWS::EC2::SecurityGroup'] },
      });
      const channel = new config.CfnDeliveryChannel(this, 'DeliveryChannel', {
        s3BucketName: bucket.bucketName,
      });
      channel.node.addDependency(recorder);
      channel.node.addDependency(bucket.policy!);
      recorderReady = channel;
    }

    // Detective control: Lambda that evaluates security groups. Both rules use it; the
    // reactive rule narrows it with the `restrictedPorts` rule parameter.
    const ruleFn = new lambda.Function(this, 'SgWorldIngressRule', {
      description: 'Custom AWS Config rule: security groups open to 0.0.0.0/0 or ::/0',
      runtime: lambda.Runtime.PYTHON_3_13,
      handler: 'sg_world_ingress.handler',
      code: lambda.Code.fromAsset(path.join(ASSETS, 'lambda')),
      timeout: cdk.Duration.seconds(30),
    });
    // PutEvaluations, plus read access for oversized configuration items.
    ruleFn.role!.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSConfigRulesExecutionRole'),
    );
    const invokePermission = new lambda.CfnPermission(this, 'ConfigInvoke', {
      action: 'lambda:InvokeFunction',
      functionName: ruleFn.functionName,
      principal: 'config.amazonaws.com',
      sourceAccount: this.account,
    });

    // Reactive control: SSM Automation document that revokes the offending rules.
    const document = new ssm.CfnDocument(this, 'RevokeWorldIngress', {
      documentType: 'Automation',
      documentFormat: 'YAML',
      content: yaml.parse(fs.readFileSync(path.join(ASSETS, 'revoke-world-ingress.yaml'), 'utf8')),
    });
    const remediationRole = new iam.Role(this, 'RemediationRole', {
      assumedBy: new iam.ServicePrincipal('ssm.amazonaws.com', {
        conditions: { StringEquals: { 'aws:SourceAccount': this.account } },
      }),
      inlinePolicies: {
        RevokeWorldIngress: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({ actions: ['ec2:DescribeSecurityGroupRules'], resources: ['*'] }),
            new iam.PolicyStatement({
              actions: ['ec2:RevokeSecurityGroupIngress'],
              resources: [`arn:${this.partition}:ec2:*:${this.account}:security-group/*`],
            }),
          ],
        }),
      },
    });

    // Conformance pack: both rules plus the remediation, deployed as one unit.
    const pack = new config.CfnConformancePack(this, 'SgControlsPack', {
      conformancePackName: `${this.stackName}-sg-controls`,
      // Values are rendered into the template rather than passed as conformance pack input
      // parameters; see the note at the top of the template.
      templateBody: fs
        .readFileSync(path.join(ASSETS, 'conformance-pack.yaml'), 'utf8')
        .replaceAll('__RULE_LAMBDA_ARN__', ruleFn.functionArn)
        .replaceAll('__REMEDIATION_DOCUMENT_NAME__', document.ref)
        .replaceAll('__REMEDIATION_ROLE_ARN__', remediationRole.roleArn)
        .replaceAll('__RESTRICTED_PORTS__', props.restrictedPorts.join(','))
        .replaceAll('__AUTOMATIC_REMEDIATION__', String(props.automaticRemediation)),
    });
    pack.node.addDependency(invokePermission);
    if (recorderReady) pack.node.addDependency(recorderReady);

    new cdk.CfnOutput(this, 'ConformancePack', { value: pack.conformancePackName });
    new cdk.CfnOutput(this, 'RuleFunction', { value: ruleFn.functionName });
    new cdk.CfnOutput(this, 'RemediationDocument', { value: document.ref });
  }
}
