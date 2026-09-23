import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

export interface KafkaClusterStackProps extends cdk.StackProps {
  /** Apache Kafka version (Apache CDN, falls back to archive.apache.org). */
  readonly kafkaVersion: string;
  readonly instanceType: string;
  /** JVM heap for each node, e.g. "1g". */
  readonly heapSize: string;
  /** Root EBS volume size (GiB); Kafka data lives on this volume. */
  readonly volumeSizeGb: number;
  /** Nodes running broker + KRaft controller. Odd number >= 3. */
  readonly brokerCount: number;
  /** Extra CIDRs allowed to reach port 9092. The VPC CIDR is always allowed. */
  readonly clientCidrs: string[];
}

const VPC_CIDR = '10.0.0.0/16';
const CLIENT_PORT = 9092;
const CONTROLLER_PORT = 9093;

/** Returns the n-th host address of an IPv4 CIDR, e.g. hostIp('10.0.1.0/24', 10) -> 10.0.1.10. */
function hostIp(cidr: string, n: number): string {
  const base = cidr.split('/')[0].split('.').reduce((acc, octet) => acc * 256 + Number(octet), 0);
  const ip = base + n;
  return [24, 16, 8, 0].map((shift) => Math.floor(ip / 2 ** shift) % 256).join('.');
}

export class KafkaClusterStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: KafkaClusterStackProps) {
    super(scope, id, props);

    if (props.brokerCount < 3 || props.brokerCount % 2 === 0) {
      throw new Error('brokerCount must be an odd number >= 3 so the KRaft quorum can tolerate failures.');
    }

    // Public subnets let the brokers download Kafka without a NAT gateway.
    // The security group, not the subnet, keeps the Kafka ports private.
    const vpc = new ec2.Vpc(this, 'Vpc', {
      ipAddresses: ec2.IpAddresses.cidr(VPC_CIDR),
      maxAzs: props.brokerCount,
      natGateways: 0,
      subnetConfiguration: [{ name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 }],
    });
    const subnets = vpc.publicSubnets;
    if (subnets.length < props.brokerCount) {
      throw new Error(
        `Only ${subnets.length} AZs available; need ${props.brokerCount}. ` +
          'Set CDK_DEFAULT_ACCOUNT/CDK_DEFAULT_REGION (e.g. via AWS credentials) so AZs can be looked up.',
      );
    }

    const sg = new ec2.SecurityGroup(this, 'BrokerSecurityGroup', {
      vpc,
      description: 'Kafka brokers and KRaft controllers',
      allowAllOutbound: true,
    });
    sg.addIngressRule(ec2.Peer.ipv4(vpc.vpcCidrBlock), ec2.Port.tcp(CLIENT_PORT), 'Kafka clients inside the VPC');
    for (const cidr of props.clientCidrs) {
      sg.addIngressRule(ec2.Peer.ipv4(cidr), ec2.Port.tcp(CLIENT_PORT), 'Kafka clients (extra CIDR)');
    }
    sg.addIngressRule(sg, ec2.Port.tcp(CONTROLLER_PORT), 'KRaft controller quorum between nodes');

    // Instances are reached with SSM Session Manager, so there is no SSH key or port 22.
    const role = new iam.Role(this, 'BrokerRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')],
    });

    // Pinned in cdk.context.json on first synth so later deploys don't replace brokers when a new AMI ships.
    const ami = ec2.MachineImage.latestAmazonLinux2023({ cachedInContext: true });

    // Fixed private IPs (x.x.N.10) so the static controller quorum is known before launch.
    const brokerIps = subnets.slice(0, props.brokerCount).map((s) => hostIp(s.ipv4CidrBlock, 10));
    const quorumVoters = brokerIps.map((ip, i) => `${i + 1}@${ip}:${CONTROLLER_PORT}`).join(',');

    // KRaft cluster ID: 16 bytes, base64url without padding. Derived from the stack's
    // identity so it is stable across synths; override with `-c clusterId=...`.
    const clusterId: string =
      this.node.tryGetContext('clusterId') ??
      crypto.createHash('md5').update(`${this.account}/${this.region}/${this.node.addr}`).digest('base64url');

    const template = fs.readFileSync(path.join(__dirname, '..', 'assets', 'bootstrap.sh'), 'utf8');

    const instances = brokerIps.map((ip, i) => {
      const nodeId = i + 1;
      const script = template
        .replace('__KAFKA_VERSION__', props.kafkaVersion)
        .replace('__NODE_ID__', String(nodeId))
        .replace('__CLUSTER_ID__', clusterId)
        .replace('__QUORUM_VOTERS__', quorumVoters)
        .replace('__ADVERTISED_HOST__', ip)
        .replace('__HEAP_SIZE__', props.heapSize);

      const instance = new ec2.Instance(this, `Broker${nodeId}`, {
        vpc,
        vpcSubnets: { subnets: [subnets[i]] },
        instanceType: new ec2.InstanceType(props.instanceType),
        machineImage: ami,
        securityGroup: sg,
        role,
        privateIpAddress: ip,
        requireImdsv2: true,
        userData: ec2.UserData.custom(script),
        userDataCausesReplacement: true,
        blockDevices: [
          {
            deviceName: '/dev/xvda',
            volume: ec2.BlockDeviceVolume.ebs(props.volumeSizeGb, {
              volumeType: ec2.EbsDeviceVolumeType.GP3,
              encrypted: true,
            }),
          },
        ],
      });
      // Instance must not boot before the internet route exists, or the Kafka download fails.
      instance.node.addDependency(subnets[i].internetConnectivityEstablished);
      cdk.Tags.of(instance).add('Name', `${this.stackName}-broker-${nodeId}`);
      return instance;
    });

    new cdk.CfnOutput(this, 'BootstrapServers', {
      description: 'Kafka bootstrap servers (reachable from inside the VPC).',
      value: brokerIps.map((ip) => `${ip}:${CLIENT_PORT}`).join(','),
    });
    new cdk.CfnOutput(this, 'BrokerInstanceIds', {
      description: 'EC2 instance IDs, for `aws ssm start-session --target <id>`.',
      value: cdk.Fn.join(',', instances.map((inst) => inst.instanceId)),
    });
    new cdk.CfnOutput(this, 'ClusterId', { value: clusterId });
    new cdk.CfnOutput(this, 'VpcId', { value: vpc.vpcId });
  }
}
