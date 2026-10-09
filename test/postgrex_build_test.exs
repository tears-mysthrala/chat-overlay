defmodule ChatOverlay.PostgrexBuildTest do
  use ExUnit.Case, async: true

  test "compatibility patch verifies the original source and rejects later changes" do
    directory =
      Path.join(System.tmp_dir!(), "postgrex-build-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(directory, "deps/postgrex"))
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "deps/postgrex/mix.exs")
    script = Path.expand("scripts/prepare_postgrex.exs")

    original =
      File.read!("deps/postgrex/mix.exs")
      |> String.replace(
        "elixirc_options: [no_warn_undefined: [Jason]]",
        "xref: [exclude: [Jason]]"
      )

    File.write!(path, original)
    assert {_, 0} = System.cmd("elixir", [script], cd: directory, stderr_to_stdout: true)

    assert File.read!(path) ==
             String.replace(
               original,
               "xref: [exclude: [Jason]]",
               "elixirc_options: [no_warn_undefined: [Jason]]"
             )

    assert {message, status} =
             System.cmd("elixir", [script], cd: directory, stderr_to_stdout: true)

    assert status != 0
    assert message =~ "differs from reviewed"

    File.write!(path, original <> "\n# unexpected change\n")

    assert {message, status} =
             System.cmd("elixir", [script], cd: directory, stderr_to_stdout: true)

    assert status != 0
    assert message =~ "differs from reviewed"
  end
end
