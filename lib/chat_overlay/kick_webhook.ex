defmodule ChatOverlay.KickWebhook do
  @moduledoc "Only signed Kick notifications enter this route; it is not an ingest API."
  alias ChatOverlay.{Adapters, Config, Event, JSON, Source}

  @key """
  -----BEGIN PUBLIC KEY-----
  MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAq/+l1WnlRrGSolDMA+A8
  6rAhMbQGmQ2SapVcGM3zq8ANXjnhDWocMqfWcTd95btDydITa10kDvHzw9WQOqp2
  MZI7ZyrfzJuz5nhTPCiJwTwnEtWft7nV14BYRDHvlfqPUaZ+1KR4OCaO/wWIk/rQ
  L/TjY0M70gse8rlBkbo2a8rKhu69RQTRsoaf4DVhDPEeSeI5jVrRDGAMGL3cGuyY
  6CLKGdjVEM78g3JfYOvDU/RvfqD7L89TZ3iN94jrmWdGz34JNlEI5hqK8dd7C5EF
  BEbZ5jgB8s8ReQV8H+MkuffjdAj3ajDDX3DOJMIut1lBrUVD1AaSrGCKHooWoL2e
  twIDAQAB
  -----END PUBLIC KEY-----
  """
  def public_key, do: @key |> :public_key.pem_decode() |> hd() |> :public_key.pem_entry_decode()

  def call(req) do
    cond do
      req.method != "POST" ->
        reply(req, 405)

      not ChatOverlay.WebhookGate.allow?() ->
        reply(req, 429)

      oversized?(req) ->
        reply(req, 413)

      true ->
        case Plug.Conn.read_body(req, length: 65_536, read_length: 8192, read_timeout: 4000) do
          {:ok, body, req} when byte_size(body) <= 65_536 ->
            headers = Map.new(req.req_headers)

            with true <- verify(headers, body, public_key()),
                 {:ok, event} <- JSON.decode(body),
                 sources when sources != [] <- matching_sources(headers, event) do
              results =
                Enum.map(sources, fn s ->
                  if ChatOverlay.Admission.demand_count(s) > 0 do
                    case Adapters.kick(
                           headers["kick-event-type"],
                           headers["kick-event-message-id"],
                           headers["kick-event-message-timestamp"],
                           event,
                           s
                         ) do
                      {:ok, e} ->
                        accepted = Source.publish(s, e)

                        if accepted,
                          do: Source.status(s, "available"),
                          else: Source.status(s, "degraded")

                        accepted

                      _ ->
                        false
                    end
                  else
                    true
                  end
                end)

              reply(req, if(Enum.all?(results), do: 204, else: 503))
            else
              _ -> reply(req, 403)
            end

          {_, _, req} ->
            reply(req, 413)

          {:error, _} ->
            reply(req, 400)
        end
    end
  end

  defp oversized?(conn) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {size, ""} -> size > 65_536
          _ -> true
        end

      _ ->
        false
    end
  end

  def verify(headers, body, key, now \\ DateTime.utc_now()) do
    with id when is_binary(id) <- headers["kick-event-message-id"],
         true <- Event.id?(id),
         timestamp when is_binary(timestamp) <- headers["kick-event-message-timestamp"],
         {:ok, at, 0} <- DateTime.from_iso8601(timestamp),
         true <- abs(DateTime.diff(now, at)) <= 300,
         signature when is_binary(signature) and byte_size(signature) <= 1024 <-
           headers["kick-event-signature"],
         {:ok, decoded} <- Base.decode64(signature),
         true <- byte_size(body) <= 65_536 do
      :public_key.verify(id <> "." <> timestamp <> "." <> body, :sha256, decoded, key)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp matching_sources(headers, %{"broadcaster" => %{"user_id" => id}}) when is_integer(id) do
    Enum.filter(Config.sources(), fn s ->
      s["platform"] == "kick" and s["mode"] != "demo" and s["channel"] == Integer.to_string(id) and
        headers["kick-event-version"] == "1" and
        ((headers["kick-event-type"] == "chat.message.sent" and
            headers["kick-event-subscription-id"] == s["subscription_id"]) or
           (headers["kick-event-type"] == "moderation.banned" and
              is_binary(s["moderation_subscription_id"]) and
              headers["kick-event-subscription-id"] == s["moderation_subscription_id"]))
    end)
  end

  defp matching_sources(_, _), do: []

  defp reply(req, status),
    do: ChatOverlay.Web.reply(req, status, "text/plain", "")
end

defmodule ChatOverlay.WebhookGate do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def allow?, do: GenServer.call(__MODULE__, :allow)
  def init(_), do: {:ok, {System.monotonic_time(:second), 0}}

  def handle_call(:allow, _, {second, count}) do
    now = System.monotonic_time(:second)
    count = if now == second, do: count, else: 0
    {:reply, count < 250, {now, min(count + 1, 251)}}
  end
end
