defmodule Seven.Sync.ApiCommandRouter do
  @moduledoc """
    Make a syncronized command.

    Example:

    ```elixir
    defmodule MyApp.Command.Ping do
      alias __MODULE__
      require Logger

      use Seven.Sync.ApiCommandRouter,
        post: %{
          command: "Ping",
          pre_command: &Ping.pre_command/1,
          post_command: &Ping.post_command/2,
          wait_for_events: ["Pinged"]
        }

      def pre_command(%ApiRequest{} = _req) do
        Logger.debug("Ping.pre_command()")
        :ok
      end

      def post_command(%ApiRequest{} = _req, %Seven.Otters.Event{type: "Pinged"} = _event) do
        Logger.debug("Ping.post_command(): pinged event received.")
        %{ping: "ok"}
      end
    end
    ```

    `post` map can contains:
    - `command`: the command to send
    - `pre_command`: a function that will be run after to send the command, expressed in the form of `func_name(%ApiRequest{})`
    - `post_command`: a function that will be run before to send the command, expressed in the form of `func_name(%ApiRequest{}, %Seven.Otters.Event{})`
    - `wait_for_events`: list of events to wait for; this macro waits for all indicated events that are raised from the same request generated by the command above.

    Usage:
    ```
    iex> MyApp.Command.Ping.run(params)
    ```
  """

  defp is_not_nil(arg), do: not is_nil(arg)

  defmacro __using__(post: post) do
    quote location: :keep do
      alias Seven.Sync.ApiRequest

      @doc false
      @spec run(map) :: any
      def run(params) do
        %ApiRequest{
          request_id: Seven.Data.Persistence.new_id(),
          command: unquote(post).command,
          state: :unmanaged,
          params: params,
          wait_for_events: unquote(post)[:wait_for_events] || []
        }
        |> internal_pre_command
        |> subscribe_to_event_store
        |> send_command_request
        |> wait_events
        |> unsubscribe_to_event_store
        |> internal_post_command
        |> send_response
      end

      # Privates

      defp send_response(%ApiRequest{state: :managed, response: resp}), do: resp
      defp send_response(%ApiRequest{state: state}), do: state

      unquote do
        {_, _, p} = post

        if p[:pre_command] |> is_not_nil do
          quote do
            defp internal_pre_command(%ApiRequest{state: :unmanaged, command: unquote(p[:command])} = req) do
              case unquote(p[:pre_command]).(req) do
                :ok -> req
                {:ok, req} -> req
                err -> %ApiRequest{req | state: err}
              end
            end
          end
        end
      end

      defp internal_pre_command(%ApiRequest{} = req), do: req

      defp subscribe_to_event_store(%ApiRequest{state: :unmanaged, wait_for_events: []} = req),
        do: req

      defp subscribe_to_event_store(%ApiRequest{state: :unmanaged, wait_for_events: wait_for_events} = req) when length(wait_for_events) > 0 do
        wait_for_events |> Enum.each(&Seven.EventStore.EventStore.subscribe(&1, self()))
        req
      end

      defp subscribe_to_event_store(%ApiRequest{} = req), do: req

      defp send_command_request(%ApiRequest{state: :unmanaged} = req) do
        res =
          %Seven.CommandRequest{
            id: req.request_id,
            command: req.command,
            sender: __MODULE__,
            params: AtomicMap.convert(req.params, safe: false)
          }
          |> Seven.Log.command_request_sent()
          |> Seven.CommandBus.send_command_request()

        %ApiRequest{req | state: res}
      end

      defp send_command_request(%ApiRequest{} = req), do: req

      defp wait_events(%ApiRequest{state: :managed, wait_for_events: []} = req), do: req

      defp wait_events(%ApiRequest{state: :managed, wait_for_events: events} = req) do
        incoming_events = wait_for_one_of_events(req.request_id, events, [])
        %ApiRequest{req | events: incoming_events}
      end

      defp wait_events(%ApiRequest{} = req), do: req

      defp unsubscribe_to_event_store(%ApiRequest{state: :managed, wait_for_events: []} = req),
        do: req

      defp unsubscribe_to_event_store(%ApiRequest{state: :managed, wait_for_events: wait_for_events} = req) when length(wait_for_events) > 0 do
        wait_for_events |> Enum.each(&Seven.EventStore.EventStore.unsubscribe(&1, self()))
        req
      end

      defp unsubscribe_to_event_store(%ApiRequest{} = req), do: req

      unquote do
        {_, _, p} = post

        if p[:post_command] |> is_not_nil do
          quote do
            defp internal_post_command(%ApiRequest{state: :managed, command: unquote(p[:command]), events: []} = req),
              do: %ApiRequest{req | response: unquote(p[:post_command]).(req, nil)}

            defp internal_post_command(%ApiRequest{state: :managed, command: unquote(p[:command]), events: [e1]} = req),
              do: %ApiRequest{req | response: unquote(p[:post_command]).(req, e1)}
          end
        end
      end

      # no events to wait for
      defp internal_post_command(%ApiRequest{state: :managed, wait_for_events: [], events: []} = req),
        do: req

      defp internal_post_command(%ApiRequest{state: :managed, events: []} = req),
        do: %ApiRequest{req | state: :timeout}

      defp internal_post_command(%ApiRequest{} = req), do: req

      @command_timeout 5000

      defp wait_for_one_of_events(_request_id, [], incoming_events), do: incoming_events

      defp wait_for_one_of_events(request_id, events, incoming_events) do
        receive do
          %Seven.Otters.Event{request_id: ^request_id} = e ->
            if e.type in events do
              incoming_events ++ [e]
            else
              wait_for_one_of_events(request_id, events, incoming_events)
            end

          _ ->
            wait_for_one_of_events(request_id, events, incoming_events)
        after
          @command_timeout -> []
        end
      end
    end
  end
end
