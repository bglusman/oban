defmodule Oban.Integration.TelemetryTest do
  use Oban.Case

  import ExUnit.CaptureLog

  alias Oban.Telemetry

  @moduletag :integration

  @oban_opts repo: Repo, queues: [zeta: 3]

  defmodule Handler do
    def handle([:oban, :job, :start], %{start_time: start_time}, meta, pid) do
      send(pid, {:event, :start, start_time, meta})
    end

    def handle([:oban, :job, event], %{duration: duration}, meta, pid) do
      send(pid, {:event, event, duration, meta})
    end
  end

  test "telemetry events are emitted for executed jobs" do
    events = [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]]

    :telemetry.attach_many("job-handler", events, &Handler.handle/4, self())

    start_supervised!({Oban, @oban_opts})

    %Job{id: stop_id} = insert_job!(%{ref: 1, action: "OK"})
    %Job{id: exception_id} = insert_job!(%{ref: 2, action: "FAIL"})
    %Job{id: error_id} = insert_job!(%{ref: 2, action: "ERROR"})

    assert_receive {:event, :start, started_time, stop_meta}
    assert_receive {:event, :stop, stop_duration, stop_meta}
    assert_receive {:event, :exception, exception_duration, %{kind: :error} = exception_meta}
    assert_receive {:event, :exception, error_duration, %{kind: :error} = error_meta}

    assert started_time > 0
    assert stop_duration > 0
    assert exception_duration > 0
    assert error_duration > 0

    assert %{
             id: ^stop_id,
             args: %{},
             queue: "zeta",
             worker: "Oban.Integration.Worker",
             attempt: 1,
             max_attempts: 20
           } = stop_meta

    assert %{
             id: ^exception_id,
             args: %{},
             queue: "zeta",
             worker: "Oban.Integration.Worker",
             attempt: 1,
             max_attempts: 20,
             kind: :error,
             error: _,
             stacktrace: [_ | _]
           } = exception_meta

    assert %{
             id: ^error_id,
             args: %{},
             queue: "zeta",
             worker: "Oban.Integration.Worker",
             attempt: 1,
             max_attempts: 20,
             kind: :error,
             error: "ERROR",
             stacktrace: [_ | _]
           } = error_meta

    :ok = stop_supervised(Oban)
  after
    :telemetry.detach("job-handler")
  end

  test "the default handler logs detailed event information" do
    start_supervised!({Oban, @oban_opts})

    :ok = Telemetry.attach_default_logger(:warn)

    logged =
      capture_log(fn ->
        insert_job!(%{ref: 1, action: "OK"})

        assert_receive {:ok, 1}

        Process.sleep(10)
      end)

    # Start

    assert logged =~ ~s("source":"oban")
    assert logged =~ ~s("event":"job:start")
    assert logged =~ ~s("start_time":)

    # Stop

    assert logged =~ ~s("source":"oban")
    assert logged =~ ~s("event":"job:stop")
    assert logged =~ ~s("args":)
    assert logged =~ ~s("worker":"Oban.Integration.Worker")
    assert logged =~ ~s("queue":"zeta")
    assert logged =~ ~s("duration":)
  after
    :telemetry.detach("oban-default-logger")
  end

  test "the default handler logs circuit breaker information" do
    start_supervised!({Oban, @oban_opts})

    :ok = Telemetry.attach_default_logger(:warn)

    logged =
      capture_log(fn ->
        assert %{conn: conn} = :sys.get_state(Oban.Notifier)
        assert Process.exit(conn, :forced_exit)

        # Give it time to log
        Process.sleep(50)
      end)

    assert logged =~ ~s("event":"circuit:trip")
    assert logged =~ ~s("message":":forced_exit")
    assert logged =~ ~s("name":"Elixir.Oban.Notifier")
  after
    :telemetry.detach("oban-default-logger")
  end

  defp insert_job!(args) do
    args
    |> Worker.new(queue: "zeta")
    |> Repo.insert!()
  end
end
