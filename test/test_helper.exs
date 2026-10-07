Code.require_file("support/http_client.ex", __DIR__)
Code.require_file("support/media_coordinator.ex", __DIR__)
ExUnit.start()

# CI consumes the actual ExUnit result rather than counting test declarations.
if report_path = System.get_env("CI_EXUNIT_REPORT") do
  ExUnit.after_suite(fn result ->
    File.mkdir_p!(Path.dirname(report_path))
    summary = Map.take(result, [:total, :failures, :skipped, :excluded])
    File.write!(report_path, ChatOverlay.JSON.encode(summary))
  end)
end
