package terraform

deny contains sprintf("%s: SSH (port 22) is open to the internet", [r.address]) if {
	some r in input.resource_changes
	r.type == "aws_security_group"
	some rule in r.change.after.ingress
	"0.0.0.0/0" in rule.cidr_blocks
	opens_ssh(rule)
}

opens_ssh(rule) if rule.protocol == "-1"

opens_ssh(rule) if {
	rule.protocol == "tcp"
	rule.from_port <= 22
	rule.to_port >= 22
}
