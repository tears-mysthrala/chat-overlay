defmodule ChatOverlay.MixProject do
  use Mix.Project

  def project do
    [
      app: :chat_overlay,
      version: "0.1.0",
      elixir: "~> 1.20.4",
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      start_permanent: Mix.env() == :prod,
      deps: [{:bandit, "1.12.5"}, {:mint, "1.10.1"}, {:mint_web_socket, "1.0.6"}],
      aliases: [
        check: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "test --warnings-as-errors"
        ]
      ]
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :public_key],
      mod: {ChatOverlay.Application, []}
    ]
  end
end
