defmodule Oban.Telemetry do
  @moduledoc """
  Telemetry integration for event metrics, logging and error reporting.

  ### Job Events

  Oban emits the following telemetry events for each job:

  * `[:oban, :job, :start]` — at the point a job is fetched from the database and will execute
  * `[:oban, :job, :stop]` — after a job succeeds and the success is recorded in the database
  * `[:oban, :job, :exeception]` — after a job fails and the failure is recorded in the database

  All job events share the same details about the job that was executed. In addition, failed jobs
  provide the error type, the error itself, and the stacktrace. The following chart shows which
  metadata you can expect for each event:

  | event        | measures      | metadata                                                                           |
  | ------------ | -----------   | ---------------------------------------------------------------------------------- |
  | `:start`     | `:start_time` | `:id, :args, :queue, :worker, :attempt, :max_attempts`                             |
  | `:stop`      | `:duration`   | `:id, :args, :queue, :worker, :attempt, :max_attempts`                             |
  | `:exception` | `:duration`   | `:id, :args, :queue, :worker, :attempt, :max_attempts, :kind, :error, :stacktrace` |

  For `:exception` events the metadata includes details about what caused the failure. The `:kind`
  value is determined by how an error occurred. Here are the possible kinds:

  * `:error` — from an `{:error, error}` return value. Some Erlang functions may also throw an
    `:error` tuple, which will be reported as `:error`.
  * `:exit` — from a caught process exit
  * `:throw` — from a caught value, this doesn't necessarily mean that an error occurred and the
    error value is unpredictable

  ### Circuit Events

  All processes that interact with the database have circuit breakers to prevent errors from
  crashing the entire supervision tree. Processes emit a `[:oban, :trip_circuit]` event when a
  circuit is tripped and `[:oban, :open_circuit]` when the breaker is subsequently opened again.

  | event                      | metadata                               |
  | -------------------------- | -------------------------------------- |
  | `[:oban, :circuit, :trip]` | `:error, :message, :name, :stacktrace` |
  | `[:open, :circuit, :open]` | `:name`                                |

  Metadata

  * `:error` — the error that tripped the circuit, see the error kinds breakdown above
  * `:name` — the registered name of the process that tripped a circuit, i.e. `Oban.Notifier`
  * `:message` — a formatted error message describing what went wrong
  * `:stacktrace` — exception stacktrace, when available

  ## Default Logger

  A default log handler that emits structured JSON is provided, see `attach_default_logger/0` for
  usage. Otherwise, if you would prefer more control over logging or would like to instrument
  events you can write your own handler.

  ## Examples

  A handler that only logs a few details about failed jobs:

  ```elixir
  defmodule MicroLogger do
    require Logger

    def handle_event([:oban, :job, :exception], %{duration: duration}, meta, nil) do
      Logger.warn("[#\{meta.queue}] #\{meta.worker} failed in #\{duration}")
    end
  end

  :telemetry.attach("oban-logger", [:oban, :exception], &MicroLogger.handle_event/4, nil)
  ```

  Another great use of execution data is error reporting. Here is an example of integrating with
  [Honeybadger][honey], but only reporting jobs that have failed 3 times or more:

  ```elixir
  defmodule ErrorReporter do
    def handle_event([:oban, :job, :exception], _, %{attempt: attempt} = meta, _) do
      if attempt >= 3 do
        context = Map.take(meta, [:id, :args, :queue, :worker])

        Honeybadger.notify(meta.error, context, meta.stack)
      end
    end
  end

  :telemetry.attach("oban-errors", [:oban, :job, :exception], &ErrorReporter.handle_event/4, [])
  ```

  [honey]: https://honeybadger.io
  """
  @moduledoc since: "0.4.0"

  require Logger

  @doc """
  Attaches a default structured JSON Telemetry handler for logging.

  This function attaches a handler that outputs logs with the following fields:

  * `args` — a map of the job's raw arguments
  * `duration` — the job's runtime duration, in the native time unit
  * `event` — either `:success` or `:failure` dependening on whether the job succeeded or errored
  * `queue` — the job's queue
  * `source` — always "oban"
  * `start_time` — when the job started, in microseconds
  * `worker` — the job's worker module

  ## Examples

  Attach a logger at the default `:info` level:

      :ok = Oban.Telemetry.attach_default_logger()

  Attach a logger at the `:debug` level:

      :ok = Oban.Telemetry.attach_default_logger(:debug)
  """
  @doc since: "0.4.0"
  @spec attach_default_logger() :: :ok | {:error, :already_exists}
  def attach_default_logger(level \\ :info) do
    events = [
      [:oban, :job, :start],
      [:oban, :job, :stop],
      [:oban, :job, :exception],
      [:oban, :circuit, :trip],
      [:oban, :circuit, :open]
    ]

    :telemetry.attach_many("oban-default-logger", events, &handle_event/4, level)
  end

  @doc false
  @spec handle_event([atom()], map(), map(), Logger.level()) :: :ok
  def handle_event([:oban, :job, event], measure, meta, level) do
    select_meta = Map.take(meta, [:args, :worker, :queue])

    message =
      measure
      |> Map.take([:duration, :start_time])
      |> Map.merge(select_meta)

    log_message(level, "job:#{event}", message)
  end

  def handle_event([:oban, :circuit, event], _measure, meta, level) do
    log_message(level, "circuit:#{event}", Map.take(meta, [:error, :message, :name]))
  end

  defp log_message(level, event, message) do
    Logger.log(level, fn ->
      message
      |> Map.put(:event, event)
      |> Map.put(:source, "oban")
      |> Jason.encode!()
    end)
  end
end
