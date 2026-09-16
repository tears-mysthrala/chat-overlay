defmodule ChatOverlayTest do
  use ExUnit.Case, async: true

  test "reports the authorized bootstrap phase" do
    assert ChatOverlay.phase() == :f0
  end

  test "does not expose platform or account capabilities in F0" do
    refute function_exported?(ChatOverlay, :connect_platform, 2)
    refute function_exported?(ChatOverlay, :create_account, 1)
  end
end
