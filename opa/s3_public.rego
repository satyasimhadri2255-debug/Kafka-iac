package terraform

deny contains sprintf("%s: S3 public access is not blocked", [r.address]) if {
	some r in input.resource_changes
	r.type == "aws_s3_bucket_public_access_block"
	some s in ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"]
	r.change.after[s] != true
}

deny contains sprintf("%s: S3 ACL is public", [r.address]) if {
	some r in input.resource_changes
	r.type in {"aws_s3_bucket", "aws_s3_bucket_acl"}
	r.change.after.acl in {"public-read", "public-read-write"}
}
