defmodule Tvplayer.Recordings.Runner do
  @moduledoc """
  Behaviour for recording transcode runners that write a compressed MP4.
  """

  @type opts :: %{
          required(:uuid) => String.t(),
          required(:input_url) => String.t(),
          required(:output_path) => String.t(),
          required(:part_path) => String.t(),
          required(:notify) => pid(),
          optional(:duration_ms) => pos_integer() | nil,
          optional(:config) => keyword()
        }

  @callback start(opts()) :: {:ok, pid()} | {:error, term()}
  @callback stop(pid()) :: :ok
end
