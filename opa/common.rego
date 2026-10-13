package terraform

open_cidrs := {"0.0.0.0/0", "::/0"}

all_protocols := {"-1", "all"}

changed contains rc if {
	some rc in input.resource_changes
	rc.change.actions != ["delete"]
}
