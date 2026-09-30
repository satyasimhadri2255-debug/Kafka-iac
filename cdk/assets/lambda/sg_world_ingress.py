"""Custom AWS Config rule: flag security groups with ingress open to 0.0.0.0/0 or ::/0.

Rule parameter `restrictedPorts` (comma-separated, optional): only flag world-open
rules that cover one of these ports. Without it, any world-open ingress is flagged.
"""
import json

import boto3

WORLD = {"0.0.0.0/0", "::/0"}
PORT_PROTOCOLS = {"tcp", "udp", "6", "17", "-1"}

config = boto3.client("config")


def find_violation(sg, ports):
    """Return a reason string if the SG configuration has a violating ingress rule."""
    for perm in sg.get("ipPermissions", []):
        cidrs = {r.get("cidrIp") for r in perm.get("ipv4Ranges", [])}
        cidrs |= {r.get("cidrIpv6") for r in perm.get("ipv6Ranges", [])}
        if not cidrs & WORLD:
            continue
        proto = str(perm.get("ipProtocol"))
        if proto == "-1":
            lo, hi = 0, 65535
        else:
            lo, hi = perm.get("fromPort", 0), perm.get("toPort", 65535)
        if not ports:
            return f"{proto} {lo}-{hi} open to the internet"
        if proto not in PORT_PROTOCOLS:
            continue
        hit = [p for p in ports if lo <= p <= hi]
        if hit:
            return f"port(s) {','.join(map(str, hit))} open to the internet"
    return None


def load_item(invoking):
    """Return the configuration item, fetching it when the notification was oversized."""
    if invoking["messageType"] != "OversizedConfigurationItemChangeNotification":
        return invoking["configurationItem"]
    summary = invoking["configurationItemSummary"]
    item = config.get_resource_config_history(
        resourceType=summary["resourceType"], resourceId=summary["resourceId"], limit=1
    )["configurationItems"][0]
    item["configuration"] = json.loads(item["configuration"])
    item["configurationItemCaptureTime"] = item["configurationItemCaptureTime"].isoformat()
    return item


def handler(event, _context):
    invoking = json.loads(event["invokingEvent"])
    params = json.loads(event.get("ruleParameters") or "{}")
    ports = [int(p) for p in str(params.get("restrictedPorts", "")).split(",") if p.strip()]
    item = load_item(invoking)

    if event.get("eventLeftScope") or item["configurationItemStatus"] in ("ResourceDeleted", "ResourceDeletedNotRecorded"):
        compliance, note = "NOT_APPLICABLE", "Resource deleted or out of scope"
    else:
        reason = find_violation(item["configuration"], ports)
        compliance = "NON_COMPLIANT" if reason else "COMPLIANT"
        note = reason or "No world-open ingress"

    config.put_evaluations(
        Evaluations=[{
            "ComplianceResourceType": item["resourceType"],
            "ComplianceResourceId": item["resourceId"],
            "ComplianceType": compliance,
            "Annotation": note[:256],
            "OrderingTimestamp": item["configurationItemCaptureTime"],
        }],
        ResultToken=event["resultToken"],
    )
