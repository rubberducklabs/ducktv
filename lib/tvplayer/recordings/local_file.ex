defmodule Tvplayer.Recordings.LocalFile do
  @moduledoc """
  Resolves a TVHeadend recording to a file on a locally mounted volume.

  When the TVHeadend recordings directory is mounted into this container,
  originals are served straight from disk (kernel `sendfile`, HTTP Range)
  and ffmpeg reads them locally instead of pulling them over HTTP.

  Configured via `config :tvplayer, :recording_files`:

    * `:local_root` - where the recordings are mounted here (`RECORDINGS_ROOT`)
    * `:tvheadend_root` - the same directory as TVHeadend reports it in
      `filename` (`TVHEADEND_RECORDINGS_ROOT`, defaults to `:local_root`)
  """

  alias Tvplayer.Tvheadend.Recording

  @spec path(Recording.t()) :: {:ok, Path.t()} | :error
  def path(%Recording{filename: filename}) when is_binary(filename) and filename != "" do
    config = Application.get_env(:tvplayer, :recording_files, [])

    with local_root when is_binary(local_root) and local_root != "" <- config[:local_root],
         tvh_root = blank_to_nil(config[:tvheadend_root]) || local_root,
         {:ok, relative} <- relative_to(filename, tvh_root),
         local_root = Path.expand(local_root),
         local = Path.expand(relative, local_root),
         true <- String.starts_with?(local, local_root <> "/"),
         true <- File.regular?(local) do
      {:ok, local}
    else
      _ -> :error
    end
  end

  def path(_recording), do: :error

  defp relative_to(filename, root) do
    root = Path.expand(root)
    filename = Path.expand(filename)

    if String.starts_with?(filename, root <> "/") do
      {:ok, String.replace_prefix(filename, root <> "/", "")}
    else
      :error
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
