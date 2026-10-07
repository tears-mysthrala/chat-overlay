defmodule ChatOverlay.ProfileStorageTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.ProfileStorage

  setup do
    dir = Path.join(System.tmp_dir!(), "profile-storage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: Path.join(dir, "profiles.json")}
  end

  test "rejects documents the loader cannot read, preserving the old file", %{
    path: path,
    dir: dir
  } do
    assert :ok = ProfileStorage.write(path, [])
    old = File.read!(path)

    assert {:error, :profile_document_too_large} =
             ProfileStorage.write(path, [%{"data" => String.duplicate("x", 65_536)}])

    assert File.read!(path) == old
    assert File.ls!(dir) == ["profiles.json"]
  end

  test "replacement does not follow a destination symlink", %{path: path, dir: dir} do
    target = Path.join(dir, "unrelated")
    File.write!(target, "keep")
    File.ln_s!(target, path)
    assert :ok = ProfileStorage.write(path, [])
    assert File.read!(target) == "keep"
    assert File.lstat!(path).type == :regular

    assert ChatOverlay.JSON.decode(File.read!(path)) ==
             {:ok, %{"profiles" => [], "media_objects" => []}}
  end

  test "concurrent fresh exports publish once without overwriting", %{path: path, dir: dir} do
    results =
      1..8
      |> Task.async_stream(fn n -> ProfileStorage.write_new(path, [%{"marker" => n}]) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, {:persist_failed, :eexist}})) == 7

    assert {:ok, %{"profiles" => [%{"marker" => winner}]}} =
             ChatOverlay.JSON.decode(File.read!(path))

    assert winner in 1..8
    assert File.ls!(dir) == ["profiles.json"]
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "fresh export refuses a destination symlink", %{path: path, dir: dir} do
    target = Path.join(dir, "unrelated")
    File.write!(target, "keep")
    File.ln_s!(target, path)
    assert {:error, {:persist_failed, :eexist}} = ProfileStorage.write_new(path, [])
    assert File.lstat!(path).type == :symlink
    assert File.read!(target) == "keep"
  end
end
