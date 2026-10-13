package terraform

ssh_port := 22

opens_ssh(protocol, _, _) if protocol in all_protocols

opens_ssh(protocol, from, to) if {
	protocol in {"tcp", "6"}
	from <= ssh_port
	to >= ssh_port
}

cidrs(rule) := [c |
	some key in ["cidr_blocks", "ipv6_cidr_blocks"]
	some c in object.get(rule, key, [])
]

deny contains msg if {
	some rc in changed
	rc.type == "aws_security_group"
	some rule in object.get(rc.change.after, "ingress", [])
	opens_ssh(rule.protocol, rule.from_port, rule.to_port)
	some cidr in cidrs(rule)
	cidr in open_cidrs
	msg := sprintf("%s: SSH (port 22) is open to %s", [rc.address, cidr])
}

deny contains msg if {
	some rc in changed
	rc.type == "aws_security_group_rule"
	rc.change.after.type == "ingress"
	opens_ssh(rc.change.after.protocol, rc.change.after.from_port, rc.change.after.to_port)
	some cidr in cidrs(rc.change.after)
	cidr in open_cidrs
	msg := sprintf("%s: SSH (port 22) is open to %s", [rc.address, cidr])
}

deny contains msg if {
	some rc in changed
	rc.type == "aws_vpc_security_group_ingress_rule"
	after := rc.change.after
	opens_ssh(after.ip_protocol, object.get(after, "from_port", 0), object.get(after, "to_port", 65535))
	some key in ["cidr_ipv4", "cidr_ipv6"]
	object.get(after, key, "") in open_cidrs
	msg := sprintf("%s: SSH (port 22) is open to %s", [rc.address, after[key]])
}
