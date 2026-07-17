defmodule Tvplayer.Tvheadend.Dvr do
  @moduledoc """
  High-level DVR operations. Always refreshes the Cache after mutations so
  TVheadend remains the single source of truth.
  """

  alias Tvplayer.Tvheadend.{Cache, Client, Recording}

  @doc """
  Records an EPG event, optionally applying pre/post padding afterwards.
  """
  def record_event(event_id, opts \\ []) do
    padding_pre = Keyword.get(opts, :start_extra)
    padding_post = Keyword.get(opts, :stop_extra)
    client_opts = Keyword.take(opts, [:config_uuid, :plug, :url, :username, :password, :auth])

    with {:ok, uuid} <- Client.record_event(event_id, client_opts),
         :ok <- maybe_apply_padding(uuid, padding_pre, padding_post, client_opts),
         {:ok, recordings} <- Cache.refresh_dvr() do
      {:ok, find_recording(recordings, uuid)}
    end
  end

  @doc """
  Creates a manual timer and refreshes the cache.
  """
  def create(attrs, opts \\ []) do
    client_opts = Keyword.take(opts, [:plug, :url, :username, :password, :auth])

    with {:ok, uuid} <- Client.create_recording(attrs, client_opts),
         {:ok, recordings} <- Cache.refresh_dvr() do
      {:ok, find_recording(recordings, uuid)}
    end
  end

  @doc """
  Updates an existing recording (times / padding) and refreshes the cache.
  """
  def update(uuid, attrs, opts \\ []) when is_binary(uuid) do
    client_opts = Keyword.take(opts, [:plug, :url, :username, :password, :auth])

    with {:ok, ^uuid} <- Client.update_recording(uuid, attrs, client_opts),
         {:ok, recordings} <- Cache.refresh_dvr() do
      {:ok, find_recording(recordings, uuid)}
    end
  end

  @doc """
  Cancels a scheduled recording or aborts an incomplete one.
  """
  def cancel(uuid, opts \\ []) when is_binary(uuid) do
    client_opts = Keyword.take(opts, [:plug, :url, :username, :password, :auth])

    with {:ok, ^uuid} <- Client.cancel_recording(uuid, client_opts),
         {:ok, _recordings} <- Cache.refresh_dvr() do
      {:ok, uuid}
    end
  end

  @doc """
  Stops a running recording.
  """
  def stop(uuid, opts \\ []) when is_binary(uuid) do
    client_opts = Keyword.take(opts, [:plug, :url, :username, :password, :auth])

    with {:ok, ^uuid} <- Client.stop_recording(uuid, client_opts),
         {:ok, _recordings} <- Cache.refresh_dvr() do
      {:ok, uuid}
    end
  end

  @doc """
  Removes a finished recording from disk.
  """
  def remove(uuid, opts \\ []) when is_binary(uuid) do
    client_opts = Keyword.take(opts, [:plug, :url, :username, :password, :auth])

    with {:ok, ^uuid} <- Client.remove_recording(uuid, client_opts),
         {:ok, _recordings} <- Cache.refresh_dvr() do
      {:ok, uuid}
    end
  end

  @doc """
  Cancels or stops depending on the recording state.
  """
  def cancel_or_stop(recording_or_uuid, opts \\ [])

  def cancel_or_stop(%Recording{uuid: uuid, state: :recording}, opts) do
    stop(uuid, opts)
  end

  def cancel_or_stop(%Recording{uuid: uuid}, opts) do
    cancel(uuid, opts)
  end

  def cancel_or_stop(uuid, opts) when is_binary(uuid) do
    case Cache.recording(uuid) do
      %Recording{} = recording -> cancel_or_stop(recording, opts)
      nil -> cancel(uuid, opts)
    end
  end

  defp maybe_apply_padding(_uuid, nil, nil, _opts), do: :ok
  defp maybe_apply_padding(_uuid, 0, 0, _opts), do: :ok

  defp maybe_apply_padding(uuid, pre, post, opts) when is_binary(uuid) do
    attrs =
      %{}
      |> maybe_put(:start_extra, pre)
      |> maybe_put(:stop_extra, post)

    case Client.update_recording(uuid, attrs, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp find_recording(recordings, uuid) when is_binary(uuid) do
    Enum.find(recordings, &(&1.uuid == uuid))
  end

  defp find_recording(_recordings, _), do: nil
end
