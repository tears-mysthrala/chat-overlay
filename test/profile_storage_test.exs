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
    assert File.read!(path) == ~s({"profiles":[]})
  end
end
