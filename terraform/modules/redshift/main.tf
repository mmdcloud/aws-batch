## Redshift Serverless Namespace
resource "aws_redshiftserverless_namespace" "namespace" {
  namespace_name      = var.namespace_name
  admin_username      = var.admin_username
  admin_user_password = var.admin_user_password
  db_name             = var.db_name
  # iam_roles     = [aws_iam_role.redshift_serverless_role.arn]

  tags = {
    Name = var.namespace_name
  }
}

## Redshift Serverless Workgroup
resource "aws_redshiftserverless_workgroup" "production" {
  count               = length(var.workgroups) > 0 ? 1 : 0
  namespace_name      = aws_redshiftserverless_namespace.namespace.namespace_name
  workgroup_name      = var.workgroups[count.index].workgroup_name
  base_capacity       = var.workgroups[count.index].base_capacity
  publicly_accessible = var.workgroups[count.index].publicly_accessible
  subnet_ids          = var.workgroups[count.index].subnet_ids
  security_group_ids  = var.workgroups[count.index].security_group_ids
  dynamic "config_parameter" {
    for_each = var.workgroups[0].config_parameters
    content {
      parameter_key   = config_parameter.value.parameter_key
      parameter_value = config_parameter.value.parameter_value
    }
  }
}
