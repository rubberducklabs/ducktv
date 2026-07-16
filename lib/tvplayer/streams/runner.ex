defmodule Tvplayer.Streams.Runner do
  @moduledoc """
  Behaviour for media runners that produce HLS for a channel.

  Kept intentionally small so a Membrane-based implementation can replace
  the FFmpeg runner later without changing LiveViews or session lifecycle.
  """

  @type opts :: %{
          required(:channel_uuid) => String.t(),
          required(:input_url) => String.t(),
          required(:output_dir) => String.t(),
          required(:playlist_path) => String.t(),
          optional(:config) => keyword()
        }

  @callback start(opts()) :: {:ok, pid()} | {:error, term()}
  @callback stop(pid()) :: :ok
end
