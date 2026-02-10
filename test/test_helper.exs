Logger.configure(level: :warning)
ExUnit.start(capture_log: true, exclude: [stress: true])
