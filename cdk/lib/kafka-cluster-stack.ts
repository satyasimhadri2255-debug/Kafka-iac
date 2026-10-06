import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

export class SriKafkaStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: cdk.StackProps) {
    super(scope, id, props);

    const vpc = new ec2.Vpc(this, 'SriVpc', {
      vpcName: 'sri-vpc',
      ipAddresses: ec2.IpAddresses.cidr('10.0.0.0/16'),
      availabilityZones: ['us-east-2a'],
      natGateways: 0,
      subnetConfiguration: [{ name: 'sri-public-subnet', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 }],
    });

    const secret = new secretsmanager.Secret(this, 'SriKafkaSecret', {
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ username: 'sri-kafka-admin' }),
        generateStringKey: 'password',
        passwordLength: 32,
        excludePunctuation: true,
      },
    });

    const sg = new ec2.SecurityGroup(this, 'SriKafkaSecurityGroup', {
      vpc,
      securityGroupName: 'sri-kafka-sg',
    });
    sg.addIngressRule(ec2.Peer.ipv4(vpc.vpcCidrBlock), ec2.Port.tcp(9092));

    const role = new iam.Role(this, 'SriKafkaRole', {
      roleName: 'sri-kafka-role',
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')],
    });
    secret.grantRead(role);

    const script = fs
      .readFileSync(path.join(__dirname, '..', 'assets', 'bootstrap.sh'), 'utf8')
      .replace('__SECRET_ARN__', secret.secretArn);

    const instance = new ec2.Instance(this, 'SriKafkaInstance', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: new ec2.InstanceType('c7i-flex.large'),
      machineImage: ec2.MachineImage.genericLinux({ 'us-east-2': 'ami-08be4b1b8afa29958' }),
      securityGroup: sg,
      role,
      userData: ec2.UserData.custom(script),
      instanceName: 'sri-kafka',
    });
    instance.node.addDependency(vpc.publicSubnets[0].internetConnectivityEstablished);

    new cdk.CfnOutput(this, 'SriVpcId', { value: vpc.vpcId });
    new cdk.CfnOutput(this, 'SriKafkaInstanceId', { value: instance.instanceId });
    new cdk.CfnOutput(this, 'SriKafkaBootstrapServers', { value: `${instance.instancePrivateIp}:9092` });
    new cdk.CfnOutput(this, 'SriKafkaSecretArn', { value: secret.secretArn });
  }
}
