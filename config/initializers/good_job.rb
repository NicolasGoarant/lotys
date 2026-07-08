Rails.application.configure do
  config.good_job.execution_mode = Rails.env.test? ? :external : :async
  config.good_job.max_threads    = 2
  config.good_job.queues         = "default:2;analysis:1"
  config.good_job.poll_interval  = 2
  config.good_job.shutdown_timeout = 25
end
