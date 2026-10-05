import json

import boto3

OPEN_CIDRS = {"0.0.0.0/0", "::/0"}

config = boto3.client("config")


def find_open_port(sg, ports):
    for perm in sg.get("ipPermissions", []):
        cidrs = {r.get("cidrIp") for r in perm.get("ipv4Ranges", [])}
        cidrs |= {r.get("cidrIpv6") for r in perm.get("ipv6Ranges", [])}
        if not cidrs & OPEN_CIDRS:
            continue
        if perm.get("ipProtocol") == "-1":
            low, high = 0, 65535
        else:
            low, high = perm.get("fromPort", 0), perm.get("toPort", 65535)
        if not ports:
            return f"ports {low}-{high} open to the internet"
        if perm.get("ipProtocol") not in ("tcp", "udp", "-1"):
            continue
        hit = [p for p in ports if low <= p <= high]
        if hit:
            return f"port(s) {','.join(map(str, hit))} open to the internet"
    return None


def handler(event, context):
    item = json.loads(event["invokingEvent"])["configurationItem"]
    params = json.loads(event.get("ruleParameters") or "{}")
    ports = [int(p) for p in params.get("restrictedPorts", "").split(",") if p]

    if item["configurationItemStatus"] == "ResourceDeleted":
        result, note = "NOT_APPLICABLE", "Security group deleted"
    else:
        reason = find_open_port(item["configuration"], ports)
        result = "NON_COMPLIANT" if reason else "COMPLIANT"
        note = reason or "No open ingress"

    config.put_evaluations(
        Evaluations=[{
            "ComplianceResourceType": item["resourceType"],
            "ComplianceResourceId": item["resourceId"],
            "ComplianceType": result,
            "Annotation": note,
            "OrderingTimestamp": item["configurationItemCaptureTime"],
        }],
        ResultToken=event["resultToken"],
    )
