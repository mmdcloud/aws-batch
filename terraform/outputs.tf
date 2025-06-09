output "job_queue_arn" {
  value = aws_batch_job_queue.test_queue.arn
}

output "job_definition_arn" {
  value = aws_batch_job_definition.test.arn
}