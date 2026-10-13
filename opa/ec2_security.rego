package terraform.ec2

open_cidrs := {"0.0.0.0/0", "::/0"}

all_protocols := {"-1", "all"}

changed contains rc if {
	some rc in input.resource_changes
	rc.change.actions != ["delete"]
}

cidrs(rule) := [c |
	some key in ["cidr_blocks", "ipv6_cidr_blocks"]
	some c in object.get(rule, key, [])
]

all_ports(protocol, _, _) if protocol in all_protocols

all_ports(_, from, to) if {
	from == 0
	to == 65535
}

deny contains msg if {
	some rc in changed
	rc.type == "aws_security_group"
	some rule in object.get(rc.change.after, "ingress", [])
	some cidr in cidrs(rule)
	cidr in open_cidrs
	msg := sprintf("%s: ingress %v-%v is open to %s", [rc.address, rule.from_port, rule.to_port, cidr])
}

deny contains msg if {
	some rc in changed
	rc.type == "aws_security_group"
	some rule in object.get(rc.change.after, "ingress", [])
	all_ports(rule.protocol, rule.from_port, rule.to_port)
	msg := sprintf("%s: ingress rule opens all ports", [rc.address])
}

deny contains msg if {
	some rc in changed
	rc.type == "aws_security_group_rule"
	rc.change.after.type == "ingress"
	some cidr in cidrs(rc.change.after)
	cidr in open_cidrs
	msg := sprintf("%s: ingress is open to %s", [rc.address, cidr])
}

deny contains msg if {
	some rc in changed
	rc.type == "aws_security_group_rule"
	rc.change.after.type == "ingress"
	all_ports(rc.change.after.protocol, rc.change.after.from_port, rc.change.after.to_port)
	msg := sprintf("%s: ingress rule opens all ports", [rc.address])
}

deny contains msg if {
	some rc in changed
	rc.type == "aws_vpc_security_group_ingress_rule"
	some key in ["cidr_ipv4", "cidr_ipv6"]
	object.get(rc.change.after, key, "") in open_cidrs
	msg := sprintf("%s: ingress is open to %s", [rc.address, rc.change.after[key]])
}

deny contains msg if {
	some rc in changed
	rc.type == "aws_vpc_security_group_ingress_rule"
	all_ports(rc.change.after.ip_protocol, object.get(rc.change.after, "from_port", 0), object.get(rc.change.after, "to_port", 65535))
	msg := sprintf("%s: ingress rule opens all ports", [rc.address])
}

imdsv2_required(after) if {
	some m in after.metadata_options
	m.http_tokens == "required"
}

metadata_disabled(after) if {
	some m in after.metadata_options
	m.http_endpoint == "disabled"
}

deny contains msg if {
	some rc in changed
	rc.type in {"aws_instance", "aws_launch_template"}
	not imdsv2_required(rc.change.after)
	msg := sprintf("%s: IMDSv2 is not enforced, set metadata_options.http_tokens = \"required\"", [rc.address])
}

deny contains msg if {
	some rc in changed
	rc.type in {"aws_instance", "aws_launch_template"}
	metadata_disabled(rc.change.after)
	msg := sprintf("%s: instance metadata service is disabled, set metadata_options.http_endpoint = \"enabled\"", [rc.address])
}

required_tags := {"Environment"}

instance_tags(after) := after.tags_all if {
	is_object(after.tags_all)
} else := after.tags if {
	is_object(after.tags)
} else := {}

deny contains msg if {
	some rc in changed
	rc.type == "aws_instance"
	tags := instance_tags(rc.change.after)
	some tag in required_tags
	trim_space(object.get(tags, tag, "")) == ""
	msg := sprintf("%s: missing required tag %q", [rc.address, tag])
}
