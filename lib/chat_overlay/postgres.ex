defmodule ChatOverlay.Postgres do
  @moduledoc """
  Bounded private storage for the trusted Profiles coordinator. SQL and context are
  never accepted from HTTP. Its callers perform Session/OAuth authorization before
  entering the coordinator; source/cleanup/token jobs are internal service actions.
  A compromised BEAM can select contexts: this is not the ARCH-06 process boundary.
  """
  alias ChatOverlay.{Config, JSON, MediaLedger}
  @runtime ChatOverlay.Postgres.Runtime
  @bootstrap ChatOverlay.Postgres.Bootstrap

  def validate_runtime!(pool \\ @runtime) do
    validate_identity!(pool, "overlay_runtime")
  end

  def validate_bootstrap!(pool \\ @bootstrap) do
    validate_identity!(pool, "overlay_bootstrap")
  end

  defp validate_identity!(pool, expected) do
    %{rows: [[^expected, false, false, false, false, false]]} =
      Postgrex.query!(
        pool,
        "SELECT current_user, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication FROM pg_roles WHERE rolname=current_user",
        []
      )

    %{rows: [[0]]} =
      Postgrex.query!(
        pool,
        "SELECT count(*) FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname=current_user)",
        []
      )

    %{rows: rows} =
      Postgrex.query!(
        pool,
        "SELECT c.relname,c.relrowsecurity,c.relforcerowsecurity,pg_get_userbyid(c.relowner)=current_user FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='overlay' AND c.relname IN ('profiles','accounts','objects') ORDER BY c.relname",
        []
      )

    true =
      rows == [
        ["accounts", true, true, false],
        ["objects", true, true, false],
        ["profiles", true, true, false]
      ]

    %{rows: [[false]]} =
      Postgrex.query!(pool, "SELECT has_schema_privilege(current_user,'overlay','CREATE')", [])

    %{rows: grants} =
      Postgrex.query!(
        pool,
        "SELECT has_table_privilege(current_user,c.oid,'SELECT'),has_table_privilege(current_user,c.oid,'INSERT'),has_table_privilege(current_user,c.oid,'UPDATE'),has_table_privilege(current_user,c.oid,'DELETE'),has_table_privilege(current_user,c.oid,'TRUNCATE'),has_table_privilege(current_user,c.oid,'TRIGGER'),has_table_privilege(current_user,c.oid,'REFERENCES') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='overlay' AND c.relname IN ('profiles','accounts','objects')",
        []
      )

    permissions =
      if expected == "overlay_runtime",
        do: [true, true, true, true, false, false, false],
        else: [true, false, false, false, false, false, false]

    true = length(grants) == 3 and Enum.all?(grants, &(&1 == permissions))
    :ok
  end

  def export!(pool \\ @bootstrap) do
    validate_bootstrap!(pool)

    {:ok, document} =
      Postgrex.transaction(pool, fn conn ->
        Postgrex.query!(conn, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", [])
        document = read_document(conn)
        validate_document!(document)
      end)

    document
  end

  # A single coordinator is supported. The lock serializes other local/offline
  # writers; compare the previous scoped value so a stale instance cannot overwrite.
  def replace(before, candidate, pool \\ @runtime, authorization \\ :service) do
    validate_document!(candidate)
    handles = changed_handles(before, candidate)

    true =
      authorization == :service or
        (match?({:profile, _}, authorization) and
           Enum.all?(handles, &(&1 == elem(authorization, 1))))

    case Postgrex.transaction(pool, fn conn ->
           Postgrex.query!(conn, "SELECT pg_advisory_xact_lock(510005)", [])

           Enum.each(handles, fn handle ->
             scoped(conn, handle)
             expected = scope_document(before, handle)

             if read_document(conn) != canonical(expected),
               do: Postgrex.rollback(conn, :stale_storage)

             write_scope(conn, handle, scope_document(candidate, handle))
           end)

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, :stale_storage} -> {:error, :stale_storage}
      {:error, _} -> {:error, :database_unavailable}
    end
  rescue
    _ -> {:error, :database_unavailable}
  catch
    :exit, _ -> {:error, :database_unavailable}
  end

  def validate_document!(%{"profiles" => profiles, "media_objects" => objects} = document) do
    {:ok, _} = Config.validate(profiles)
    true = MediaLedger.valid?(objects)
    true = byte_size(JSON.encode(document)) <= 65_536
    document
  end

  def canonical(document) do
    %{
      "profiles" => Enum.sort_by(document["profiles"], & &1["handle"]),
      "media_objects" => Enum.sort_by(document["media_objects"], & &1["key"])
    }
  end

  def digest(document),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(canonical(document), [:deterministic]))
      |> Base.encode16(case: :lower)

  defp scope_document(document, handle) do
    %{
      "profiles" => Enum.filter(document["profiles"], &(&1["handle"] == handle)),
      "media_objects" => Enum.filter(document["media_objects"], &(&1["handle"] == handle))
    }
  end

  defp changed_handles(before, candidate) do
    handles =
      for doc <- [before, candidate],
          row <- doc["profiles"] ++ doc["media_objects"],
          do: row["handle"]

    handles
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&(scope_document(before, &1) != scope_document(candidate, &1)))
  end

  defp scoped(conn, handle) do
    true = Config.handle?(handle)
    Postgrex.query!(conn, "SELECT set_config('overlay.handle',$1,true)", [handle])
  end

  defp read_document(conn) do
    %{rows: profiles} =
      Postgrex.query!(
        conn,
        "SELECT handle,body,accounts_present FROM overlay.profiles ORDER BY handle",
        []
      )

    %{rows: accounts} =
      Postgrex.query!(
        conn,
        "SELECT handle,provider,body FROM overlay.accounts ORDER BY handle,provider",
        []
      )

    %{rows: objects} = Postgrex.query!(conn, "SELECT body FROM overlay.objects ORDER BY key", [])

    profiles =
      Enum.map(profiles, fn [handle, body, present] ->
        profile = decode!(body)
        true = profile["handle"] == handle

        if present do
          linked =
            for [^handle, provider, data] <- accounts, into: %{}, do: {provider, decode!(data)}

          Map.put(profile, "linked_accounts", linked)
        else
          profile
        end
      end)

    %{
      "profiles" => profiles,
      "media_objects" => Enum.map(objects, fn [body] -> decode!(body) end)
    }
  end

  defp decode!(body) do
    {:ok, data} = JSON.decode(body)
    data
  end

  defp write_scope(conn, handle, document) do
    Postgrex.query!(conn, "DELETE FROM overlay.objects WHERE handle=$1", [handle])
    Postgrex.query!(conn, "DELETE FROM overlay.accounts WHERE handle=$1", [handle])

    case document["profiles"] do
      [] ->
        Postgrex.query!(conn, "DELETE FROM overlay.profiles WHERE handle=$1", [handle])

      [profile] ->
        Postgrex.query!(
          conn,
          "INSERT INTO overlay.profiles(handle,body,accounts_present) VALUES($1,$2,$3) ON CONFLICT(handle) DO UPDATE SET body=excluded.body,accounts_present=excluded.accounts_present",
          [
            handle,
            JSON.encode(
              if(is_map(profile["linked_accounts"]),
                do: Map.delete(profile, "linked_accounts"),
                else: profile
              )
            ),
            is_map(profile["linked_accounts"])
          ]
        )

        Enum.each(profile["linked_accounts"] || %{}, fn {provider, data} ->
          Postgrex.query!(
            conn,
            "INSERT INTO overlay.accounts(handle,provider,body) VALUES($1,$2,$3)",
            [handle, provider, JSON.encode(data)]
          )
        end)
    end

    Enum.each(document["media_objects"], fn object ->
      Postgrex.query!(conn, "INSERT INTO overlay.objects(handle,key,body) VALUES($1,$2,$3)", [
        handle,
        object["key"],
        JSON.encode(object)
      ])
    end)
  end
end
