defmodule ChatOverlay.Reauthentication.EnrollmentTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.Reauthentication
  alias ChatOverlay.Reauthentication.Enrollment

  test "offline enrollment requires a matching code and never overwrites a directory" do
    dir = Path.join(System.tmp_dir!(), "enroll-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    assert :ok = Enrollment.prepare(dir, "alice", "twitch", "alice-id")
    assert {:error, :eexist} = Enrollment.prepare(dir, "alice", "twitch", "alice-id")
    assert {:error, :enrollment_not_confirmed} = Enrollment.confirm(dir, "xxxxxx")
    refute File.exists?(Path.join(dir, "credentials.json"))

    assert {:ok, %{"alice" => entry}} =
             Reauthentication.load_credentials(Path.join(dir, "pending.json"))

    assert :ok = Enrollment.confirm(dir, NimbleTOTP.verification_code(entry.secret))

    assert {:ok, %{"alice" => ^entry}} =
             Reauthentication.load_credentials(Path.join(dir, "credentials.json"))

    refute File.exists?(Path.join(dir, "enrollment.txt"))
    refute File.exists?(Path.join(dir, "pending.json"))
    assert Bitwise.band(File.stat!(Path.join(dir, "credentials.json")).mode, 0o077) == 0
  end
end
