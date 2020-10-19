defmodule Seven.Otters.Projection do
  @moduledoc false

  defmacro __using__(listener_of_events: listener_of_events) do
    quote location: :keep do
      use GenServer

      @test_env Mix.env() == :test

      alias Seven.Utils.Snapshot
      use Seven.Utils.Tagger
      @tag :projection

      # API
      def start_link(opts \\ []) do
        projection_name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, opts ++ [name: projection_name])
      end

      @spec filter((any -> any), atom) :: List.t()
      def filter(map_func, process_name \\ __MODULE__), do: GenServer.call(process_name, {:filter, map_func})

      @spec query(Atom.t(), Map.t(), atom) :: List.t()
      def query(query_filter, params, process_name \\ __MODULE__),
        do: GenServer.call(process_name, {:query, query_filter, params})

      @spec state(atom) :: List.t()
      def state(process_name \\ __MODULE__), do: GenServer.call(process_name, :state)

      @spec pid(atom) :: pid
      def pid(process_name \\ __MODULE__), do: GenServer.call(process_name, :pid)

      @spec clean(atom) :: pid
      def clean(process_name \\ __MODULE__), do: GenServer.call(process_name, :clean)

      if @test_env do
        @spec send(Seven.Otters.Event, atom) :: pid
        def send(%Seven.Otters.Event{} = e, process_name \\ __MODULE__), do: GenServer.call(process_name, {:send, e})
      end

      #
      # Callbacks
      #
      def init(opts), do: {:ok, opts, {:continue, :rehydrate}}

      def handle_continue(:rehydrate, opts) do
        Seven.Log.info("Projection #{registered_name()} started.")

        subscribe = Keyword.get(opts, :subscribe_to_eventstore, true)
        subscribe_to_event_store(subscribe)
        {state, snapshot} = rehydratate(subscribe)

        {:noreply,
         %{
           internal_state: state,
           snapshot: snapshot
         }}
      end

      def handle_call({:query, query_filter, params}, _from, %{internal_state: internal_state} = state) do
        params = AtomicMap.convert(params, safe: false)

        res =
          case pre_handle_query(query_filter, params, internal_state) do
            :ok -> handle_query(query_filter, params, internal_state)
            err -> err
          end

        {:reply, res, state}
      end

      def handle_call({:filter, filter_func}, _from, %{internal_state: internal_state} = state),
        do: {:reply, internal_state |> Enum.filter(filter_func), state}

      def handle_call(:state, _from, state), do: {:reply, state, state}

      def handle_call(:pid, _from, state), do: {:reply, self(), state}

      def handle_call(:clean, _from, state) do
        {:reply, :ok, %{state | internal_state: init_state(), snapshot: Snapshot.new(registered_name())}}
      end

      def handle_call({:send, event}, _from, %{internal_state: internal_state} = state) do
        Seven.Log.event_received(event, registered_name())
        {:reply, event, %{state | internal_state: handle_event(event, internal_state)}}
      end

      def terminate(:normal, _state) do
        Seven.Log.debug("Terminating #{registered_name()}(#{inspect(self())}) for :normal")
      end

      def terminate(reason, _state) do
        Seven.Log.debug("Terminating #{registered_name()}(#{inspect(self())}) for #{inspect(reason)}")
      end

      def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
        Seven.Log.debug("Dying #{registered_name()}(#{inspect(pid)}): #{inspect(state)}")
        {:noreply, state}
      end

      def handle_info(%Seven.Otters.Event{} = event, %{internal_state: internal_state, snapshot: snapshot} = state) do
        Seven.Log.event_received(event, registered_name())
        new_internal_state = handle_event(event, internal_state)

        #snapshot =
        #  snapshot
        #  |> Snapshot.add_events([event])
        #  |> Snapshot.snap_if_needed(new_internal_state)

        {:noreply, %{state | internal_state: new_internal_state, snapshot: nil}} #snapshot}}
      end

      def handle_info(_, state), do: {:noreply, state}

      #
      # Privates
      #
      @spec apply_events(List.t(), Map.t()) :: Map.t()
      defp apply_events([], state), do: state

      defp apply_events([event | events], state) do
        Seven.Log.event_received(event, registered_name())
        new_state = handle_event(event, state)
        apply_events(events, new_state)
      end

      defp rehydratate_by_snapshot(nil) do
        events =
          unquote(listener_of_events)
          |> Seven.EventStore.EventStore.events_by_types()

        Seven.Log.info("Processing #{length(events)} events for #{registered_name()}.")
        state = apply_events(events, init_state())

        Seven.Log.info("Projection #{registered_name()} rehydrated")

        snapshot =
          Snapshot.new(registered_name())
          |> Snapshot.add_events(events)

        {state, snapshot}
      end

      defp rehydratate_by_snapshot(snapshot) do
        snapshot = struct(Snapshot, snapshot)
        last_seen_event = Seven.EventStore.EventStore.event_by_id(snapshot.last_event_id)

        new_events =
          unquote(listener_of_events)
          |> Seven.EventStore.EventStore.events_by_types(last_seen_event.counter)

        Seven.Log.info("Processing #{length(new_events)} events for #{registered_name()}.")
        state = apply_events(new_events, Snapshot.get_state(snapshot.state))

        Seven.Log.info("Projection #{registered_name()} rehydrated")

        snapshot =
          Snapshot.new(snapshot)
          |> Snapshot.add_events(new_events)

        {state, snapshot}
      end

      defp rehydratate(true) do
        rehydratate_by_snapshot(Snapshot.get_snap(registered_name()))
      end

      defp rehydratate(_) do
        Seven.Log.info("Projection #{registered_name()} is not subscribed to EventStore.")
        {init_state(), Snapshot.new(registered_name())}
      end

      defp subscribe_to_event_store(true) do
        unquote(listener_of_events) |> Enum.each(&Seven.EventStore.EventStore.subscribe(&1, self()))
        :ok
      end

      defp subscribe_to_event_store(_), do: :ok

      defp registered_name() do
        {:registered_name, name} = Process.info(self(), :registered_name)
        name
      end

      @before_compile Seven.Otters.Projection
    end
  end

  defmacro __before_compile__(_env) do
    quote generated: true do
      defp handle_event(event, _state), do: raise("Event #{inspect(event)} is not handled correctly by #{registered_name()}")
      defp pre_handle_query(query, _params, _state), do: raise("Query #{inspect(query)} does not exist in #{registered_name()}: missing pre_handle_query()")
      defp handle_query(query, _params, state), do: raise("Query #{inspect(query)} does not exist in #{registered_name()}: missing handle_query()")
    end
  end
end
