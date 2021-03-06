defmodule EventStore.Notifications.Reader do
  @moduledoc false

  # Reads events from storage by each event number range received.

  use GenStage

  alias EventStore.RecordedEvent
  alias EventStore.Storage

  defmodule State do
    defstruct [:conn, :schema, :serializer, :subscribe_to]

    def new(opts) do
      %State{
        conn: Keyword.fetch!(opts, :conn),
        schema: Keyword.fetch!(opts, :schema),
        serializer: Keyword.fetch!(opts, :serializer),
        subscribe_to: Keyword.fetch!(opts, :subscribe_to)
      }
    end
  end

  def start_link(opts) do
    {start_opts, reader_opts} =
      Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt, :hibernate_after])

    state = State.new(reader_opts)

    GenStage.start_link(__MODULE__, state, start_opts)
  end

  # Starts a permanent subscription to the listener producer stage which will
  # automatically start requesting items.
  def init(%State{} = state) do
    %State{subscribe_to: subscribe_to} = state

    {:producer_consumer, state,
     [
       dispatcher: GenStage.BroadcastDispatcher,
       subscribe_to: [{subscribe_to, max_demand: 1}]
     ]}
  end

  # Fetch events from storage and pass onwards to subscibers
  def handle_events(events, _from, state) do
    stream_events = Enum.map(events, &read_events(&1, state))

    {:noreply, stream_events, state}
  end

  defp read_events(
         {stream_uuid, stream_id, from_stream_version, to_stream_version},
         %State{} = state
       ) do
    %State{conn: conn, schema: schema, serializer: serializer} = state

    count = to_stream_version - from_stream_version + 1

    with {:ok, events} <-
           Storage.read_stream_forward(conn, stream_id, from_stream_version, count, schema: schema),
         deserialized_events <- deserialize_recorded_events(events, serializer) do
      {stream_uuid, deserialized_events}
    end
  end

  defp deserialize_recorded_events(recorded_events, serializer) do
    Enum.map(recorded_events, &RecordedEvent.deserialize(&1, serializer))
  end
end
