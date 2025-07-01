output "endpoints" {
  value = aws_redshiftserverless_workgroup.production[*]
}