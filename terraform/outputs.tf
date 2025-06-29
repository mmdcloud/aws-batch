output "job_queue_arn" {
  value = aws_batch_job_queue.batch_job_queue.arn
}

output "job_definition_arn" {
  value = aws_batch_job_definition.batch_job_definition.arn
}