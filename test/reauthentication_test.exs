defmodule ChatOverlay.ReauthenticationTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{JSON, Reauthentication}

  test "library preserves RFC 6238 SHA1 vectors at six digits" do
    secret = "12345678901234567890"

    for {time, expected} <- [
          {59, "287082"},
          {1_111_111_109, "081804"},
          {1_111_111_111, "050471"},
          {1_234_567_890, "005924"},
          {2_000_000_000, "279037"},
          {20_000_000_000, "353130"}
        ] do
      assert NimbleTOTP.verification_code(secret, time: time) == expected
    end
  end

  setup do
    path = Path.join(System.tmp_dir!(), "reauth-#{System.unique_integer([:positive])}.json")
    secret = NimbleTOTP.secret()

    File.write!(
      path,
      JSON.encode([
        %{
          "handle" => "alice",
          "provider" => "twitch",
          "user_id" => "alice-id",
          "secret" => Base.encode32(secret, padding: false)
        }
      ])
    )

    File.chmod!(path, 0o600)
    {:ok, clock} = Agent.start_link(fn -> 1_800_000_001 end)
    now = fn -> Agent.get(clock, & &1) end

    verifier =
      start_supervised!({Reauthentication, name: __MODULE__.Verifier, path: path, clock: now})

    on_exit(fn -> File.rm(path) end)

    %{
      verifier: verifier,
      clock: clock,
      secret: secret,
      path: path,
      session: %{"handle" => "alice", "provider" => "twitch", "user_id" => "alice-id"}
    }
  end

  test "boot excludes old interval; a current code is accepted once", c do
    code = NimbleTOTP.verification_code(c.secret, time: 1_800_000_001)

    assert {:error, :reauthentication_required} =
             Reauthentication.consume(c.session, code, c.verifier)

    Agent.update(c.clock, fn _ -> 1_800_000_031 end)

    assert {:error, :reauthentication_required} =
             Reauthentication.consume(c.session, code, c.verifier)

    current = NimbleTOTP.verification_code(c.secret, time: 1_800_000_031)
    assert :ok = Reauthentication.consume(c.session, current, c.verifier)

    assert {:error, :reauthentication_required} =
             Reauthentication.consume(c.session, current, c.verifier)
  end

  test "future codes, forged identity and other profiles cannot consume the factor", c do
    Agent.update(c.clock, fn _ -> 1_800_000_031 end)
    code = NimbleTOTP.verification_code(c.secret, time: 1_800_000_031)
    future = NimbleTOTP.verification_code(c.secret, time: 1_800_000_061)

    assert {:error, :reauthentication_required} =
             Reauthentication.consume(c.session, future, c.verifier)

    assert {:error, :reauthentication_required} =
             Reauthentication.consume(%{c.session | "user_id" => "attacker"}, code, c.verifier)

    assert {:error, :reauthentication_not_configured} =
             Reauthentication.consume(%{c.session | "handle" => "bob"}, code, c.verifier)

    assert :ok = Reauthentication.consume(c.session, code, c.verifier)
  end

  test "parallel submissions accept one code once", c do
    Agent.update(c.clock, fn _ -> 1_800_000_031 end)
    code = NimbleTOTP.verification_code(c.secret, time: 1_800_000_031)

    results =
      1..4
      |> Task.async_stream(fn _ -> Reauthentication.consume(c.session, code, c.verifier) end)
      |> Enum.to_list()

    assert Enum.count(results, &(&1 == {:ok, :ok})) == 1
  end

  test "five attempts impose a five minute bound independent of browser session", c do
    Agent.update(c.clock, fn _ -> 1_800_000_031 end)

    for _ <- 1..5,
        do:
          assert(
            {:error, :reauthentication_required} =
              Reauthentication.consume(c.session, "xxxxxx", c.verifier)
          )

    code = NimbleTOTP.verification_code(c.secret, time: 1_800_000_031)

    assert {:error, :reauthentication_rate_limited} =
             Reauthentication.consume(c.session, code, c.verifier)

    Agent.update(c.clock, fn _ -> 1_800_000_331 end)

    assert :ok =
             Reauthentication.consume(
               c.session,
               NimbleTOTP.verification_code(c.secret, time: 1_800_000_331),
               c.verifier
             )
  end

  test "restart cannot reuse a code from the interrupted interval", c do
    Agent.update(c.clock, fn _ -> 1_800_000_031 end)
    code = NimbleTOTP.verification_code(c.secret, time: 1_800_000_031)
    assert :ok = Reauthentication.consume(c.session, code, c.verifier)
    :ok = stop_supervised(Reauthentication)

    fresh =
      start_supervised!(
        {Reauthentication,
         name: __MODULE__.Verifier, path: c.path, clock: fn -> Agent.get(c.clock, & &1) end}
      )

    assert {:error, :reauthentication_required} = Reauthentication.consume(c.session, code, fresh)
  end

  test "configuration is bounded, strict and diagnostics redact secrets", c do
    status = :sys.get_status(c.verifier) |> inspect()
    refute status =~ Base.encode32(c.secret, padding: false)
    refute status =~ inspect(c.secret)
    {:ok, [entry]} = c.path |> File.read!() |> JSON.decode()

    for data <- [
          [entry, entry],
          [Map.put(entry, "extra", true)],
          [%{entry | "secret" => "invalid"}],
          List.duplicate(entry, 11)
        ] do
      File.write!(c.path, JSON.encode(data))

      assert {:error, :invalid_reauthentication_configuration} =
               Reauthentication.load_credentials(c.path)
    end
  end
end
