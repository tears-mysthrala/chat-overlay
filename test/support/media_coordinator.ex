defmodule ChatOverlay.TestMediaCoordinator do
  @moduledoc "Synthetic authenticated control-plane replies; real bytes are tested in Python."
  def request("/normalize", job) do
    hash = :crypto.hash(:sha256, job["key"]) |> Base.encode16(case: :lower)
    extension = if job["category"] == "audio", do: ".wav", else: ".png"

    {:ok,
     Map.merge(job, %{
       "state" => "ready",
       "input_key" => job["key"],
       "key" => job["handle"] <> "/validated/" <> job["job"] <> "/" <> hash <> extension,
       "input_sha256" => hash,
       "output_sha256" => hash,
       "extension" => extension,
       "mime" => if(job["category"] == "audio", do: "audio/wav", else: "image/png")
     })}
  end

  def request("/delete", %{"bucket" => "public"}), do: {:ok, %{"state" => "deleted"}}
  def request("/delete", %{"bucket" => "quarantine"}), do: {:ok, %{"state" => "reconcile"}}
end
