defmodule ChatOverlay.MixProject do
  use Mix.Project

  def project do
    [
      app: :chat_overlay,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: [],
      aliases: [check: ["format --check-formatted", "test"]]
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ChatOverlay.Application, []}
    ]
  end
end
