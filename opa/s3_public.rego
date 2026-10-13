package terraform

public_access_flags := [
	"block_public_acls",
	"block_public_policy",
	"ignore_public_acls",
	"restrict_public_buckets",
]

public_acls := {"public-read", "public-read-write", "authenticated-read"}

public_grantee_uris := {
	"http://acs.amazonaws.com/groups/global/AllUsers",
	"http://acs.amazonaws.com/groups/global/AuthenticatedUsers",
}

deny contains msg if {
	some rc in changed
	rc.type in {"aws_s3_bucket_public_access_block", "aws_s3_account_public_access_block"}
	some flag in public_access_flags
	object.get(rc.change.after, flag, false) != true
	msg := sprintf("%s: %s must be true", [rc.address, flag])
}

# Every bucket needs a public access block in the same configuration.
deny contains msg if {
	some rc in changed
	rc.type == "aws_s3_bucket"
	not rc.module_address
	not has_public_access_block(rc)
	msg := sprintf("%s: bucket has no aws_s3_bucket_public_access_block", [rc.address])
}

has_public_access_block(bucket) if {
	base := regex.replace(bucket.address, `\[[^\]]*\]$`, "")
	some r in input.configuration.root_module.resources
	r.type == "aws_s3_bucket_public_access_block"
	some ref in r.expressions.bucket.references
	refers_to(ref, base)
}

has_public_access_block(bucket) if {
	some r in input.configuration.root_module.resources
	r.type == "aws_s3_bucket_public_access_block"
	r.expressions.bucket.constant_value == bucket.change.after.bucket
}

refers_to(ref, base) if ref == base

refers_to(ref, base) if startswith(ref, concat("", [base, "."]))

refers_to(ref, base) if startswith(ref, concat("", [base, "["]))

deny contains msg if {
	some rc in changed
	rc.type in {"aws_s3_bucket", "aws_s3_bucket_acl"}
	object.get(rc.change.after, "acl", "") in public_acls
	msg := sprintf("%s: ACL %q makes the bucket public", [rc.address, rc.change.after.acl])
}

deny contains msg if {
	some rc in changed
	rc.type == "aws_s3_bucket_acl"
	some acp in object.get(rc.change.after, "access_control_policy", [])
	some grant in acp.grant
	some grantee in grant.grantee
	object.get(grantee, "uri", "") in public_grantee_uris
	msg := sprintf("%s: ACL grants access to %s", [rc.address, grantee.uri])
}

deny contains msg if {
	some rc in changed
	rc.type in {"aws_s3_bucket", "aws_s3_bucket_policy"}
	policy := object.get(rc.change.after, "policy", "")
	is_string(policy)
	policy != ""
	some stmt in statements(json.unmarshal(policy))
	stmt.Effect == "Allow"
	public_principal(stmt.Principal)
	not stmt.Condition
	msg := sprintf("%s: bucket policy allows access to any principal (*)", [rc.address])
}

statements(doc) := doc.Statement if is_array(doc.Statement)

statements(doc) := [doc.Statement] if is_object(doc.Statement)

public_principal("*")

public_principal(p) if p.AWS == "*"

public_principal(p) if "*" in p.AWS
