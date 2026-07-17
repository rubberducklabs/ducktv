defmodule Tvplayer.Tvheadend.Recording do
  @moduledoc """
  Normalized TVHeadend DVR entry representation.

  State mapping mirrors TVheadend's own tabs:

  * `:scheduled` / `:recording` → Anstehende / Laufende
  * `:completed` → Abgeschlossene
  * `:failed` → Fehlgeschlagene (real errors: data errors, time missed, …)
  * `:removed` → Gelöschte (file deleted / "File missing")
  """

  @enforce_keys [:uuid, :title, :starts_at, :ends_at, :state]
  defstruct [
    :uuid,
    :title,
    :subtitle,
    :channel_uuid,
    :channel_name,
    :starts_at,
    :ends_at,
    :start_extra,
    :stop_extra,
    :sched_status,
    :status,
    :filesize,
    :url,
    :filename,
    :enabled,
    :event_id,
    :file_removed,
    :state
  ]

  @type state :: :scheduled | :recording | :completed | :failed | :removed

  @type t :: %__MODULE__{
          uuid: String.t(),
          title: String.t(),
          subtitle: String.t() | nil,
          channel_uuid: String.t() | nil,
          channel_name: String.t() | nil,
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          start_extra: non_neg_integer(),
          stop_extra: non_neg_integer(),
          sched_status: String.t() | nil,
          status: String.t() | nil,
          filesize: non_neg_integer() | nil,
          url: String.t() | nil,
          filename: String.t() | nil,
          enabled: boolean(),
          event_id: integer() | nil,
          file_removed: boolean(),
          state: state()
        }

  def from_api(entry) when is_map(entry) do
    sched_status = Map.get(entry, "sched_status")
    status = Map.get(entry, "status")
    file_removed = truthy?(Map.get(entry, "fileremoved"))
    filesize = parse_int(Map.get(entry, "filesize"), nil)

    %__MODULE__{
      uuid: Map.fetch!(entry, "uuid"),
      title: Map.get(entry, "disp_title") || localized_title(entry) || "Ohne Titel",
      subtitle: Map.get(entry, "disp_subtitle"),
      channel_uuid: Map.get(entry, "channel"),
      channel_name: Map.get(entry, "channelname"),
      starts_at: unix_to_datetime(Map.fetch!(entry, "start")),
      ends_at: unix_to_datetime(Map.fetch!(entry, "stop")),
      start_extra: parse_int(Map.get(entry, "start_extra"), 0),
      stop_extra: parse_int(Map.get(entry, "stop_extra"), 0),
      sched_status: sched_status,
      status: status,
      filesize: filesize,
      url: Map.get(entry, "url"),
      filename: Map.get(entry, "filename"),
      enabled: Map.get(entry, "enabled", true) in [true, 1, "1"],
      event_id: parse_event_id(Map.get(entry, "broadcast")),
      file_removed: file_removed,
      state: derive_state(sched_status, status, file_removed, filesize)
    }
  end

  @doc """
  True when the recording is currently active or about to start.
  """
  def active?(%__MODULE__{state: state}), do: state in [:scheduled, :recording]

  @doc """
  True when the original recording file can be downloaded.
  """
  def downloadable?(%__MODULE__{state: :completed, file_removed: true}), do: false

  def downloadable?(%__MODULE__{state: :completed, filesize: size})
      when is_integer(size) and size > 0,
      do: true

  def downloadable?(%__MODULE__{state: :completed, url: url}) when is_binary(url) and url != "",
    do: true

  def downloadable?(%__MODULE__{state: :completed, filename: filename})
      when is_binary(filename) and filename != "",
      do: true

  def downloadable?(_), do: false

  @doc """
  Relative TVheadend path for the recording file (`dvrfile/<uuid>`).
  """
  def dvrfile_path(%__MODULE__{url: url}) when is_binary(url) and url != "" do
    "/" <> String.trim_leading(url, "/")
  end

  def dvrfile_path(%__MODULE__{uuid: uuid}) when is_binary(uuid) do
    "/dvrfile/" <> uuid
  end

  @doc """
  Safe download filename derived from the TVH path or title.
  """
  def download_filename(%__MODULE__{} = recording) do
    ext =
      case recording.filename do
        path when is_binary(path) and path != "" -> Path.extname(path)
        _ -> ".ts"
      end

    ext = if ext == "", do: ".ts", else: ext

    base =
      case recording.filename do
        path when is_binary(path) and path != "" ->
          path |> Path.basename() |> Path.rootname()

        _ ->
          recording.title
      end

    sanitize_filename(base) <> ext
  end

  @doc """
  Filename for the compressed web MP4 variant.
  """
  def web_download_filename(%__MODULE__{} = recording) do
    base =
      case recording.filename do
        path when is_binary(path) and path != "" ->
          path |> Path.basename() |> Path.rootname()

        _ ->
          recording.title
      end

    sanitize_filename(base) <> ".mp4"
  end

  @doc """
  Human-readable German label for the recording state.
  """
  def state_label(:scheduled), do: "Geplant"
  def state_label(:recording), do: "Läuft"
  def state_label(:completed), do: "Abgeschlossen"
  def state_label(:failed), do: "Fehlgeschlagen"
  def state_label(:removed), do: "Gelöscht"

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
    |> String.replace(~r/[\/\\?%*:|"<>]+/u, "_")
    |> String.trim()
    |> case do
      "" -> "aufnahme"
      cleaned -> String.slice(cleaned, 0, 120)
    end
  end

  defp derive_state(_sched, _status, true, _filesize), do: :removed

  defp derive_state(sched_status, status, _file_removed, _filesize)
       when is_binary(status) and status != "" do
    down = String.downcase(status)

    cond do
      String.contains?(down, "file missing") -> :removed
      String.contains?(down, "file not created") -> :removed
      true -> derive_from_status_or_sched(down, sched_status)
    end
  end

  defp derive_state(sched_status, _status, _file_removed, _filesize) do
    derive_sched_only(sched_status)
  end

  defp derive_from_status_or_sched(down, sched_status) do
    cond do
      # Check scheduled before recording — "Scheduled for recording" contains both.
      String.contains?(down, "scheduled") -> :scheduled
      String.starts_with?(down, "recording") -> :recording
      String.contains?(down, "completed ok") -> :completed
      String.contains?(down, "too many data errors") -> :failed
      String.contains?(down, "time missed") -> :failed
      String.contains?(down, "aborted") -> :failed
      String.contains?(down, "failed") -> :failed
      String.contains?(down, "error") -> :failed
      true -> derive_sched_only(sched_status)
    end
  end

  defp derive_sched_only("scheduled"), do: :scheduled
  defp derive_sched_only("recording"), do: :recording
  defp derive_sched_only("recordingError"), do: :recording
  defp derive_sched_only("completed"), do: :completed
  defp derive_sched_only("completedError"), do: :failed
  defp derive_sched_only("completedWarning"), do: :completed
  defp derive_sched_only("completedRerecord"), do: :completed
  defp derive_sched_only(_), do: :scheduled

  defp truthy?(value) when value in [true, 1, "1"], do: true
  defp truthy?(_), do: false

  defp localized_title(%{"title" => title}) when is_map(title) do
    Map.values(title) |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp localized_title(_), do: nil

  defp parse_event_id(nil), do: nil
  defp parse_event_id(id) when is_integer(id), do: id

  defp parse_event_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp parse_event_id(_), do: nil

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp unix_to_datetime(seconds) when is_integer(seconds) do
    DateTime.from_unix!(seconds)
  end
end
