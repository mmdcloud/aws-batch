output "job_queue_arn" {
  value = aws_batch_job_queue.batch_queue.arn
}

output "job_definition_arn" {
  value = aws_batch_job_definition.example_job.arn
}