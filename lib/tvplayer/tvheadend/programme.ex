defmodule Tvplayer.Tvheadend.Programme do
  @moduledoc """
  Normalized TVHeadend EPG programme representation.
  """

  @enforce_keys [:event_id, :channel_uuid, :title, :starts_at, :ends_at]
  defstruct [
    :event_id,
    :channel_uuid,
    :channel_name,
    :channel_number,
    :title,
    :subtitle,
    :summary,
    :description,
    :starts_at,
    :ends_at,
    :next_event_id,
    :image,
    :dvr_uuid,
    :dvr_state
  ]

  @type t :: %__MODULE__{
          event_id: integer(),
          channel_uuid: String.t(),
          channel_name: String.t() | nil,
          channel_number: String.t() | integer() | nil,
          title: String.t(),
          subtitle: String.t() | nil,
          summary: String.t() | nil,
          description: String.t() | nil,
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          next_event_id: integer() | nil,
          image: String.t() | nil,
          dvr_uuid: String.t() | nil,
          dvr_state: String.t() | nil
        }

  def from_api(entry) when is_map(entry) do
    %__MODULE__{
      event_id: Map.fetch!(entry, "eventId"),
      channel_uuid: Map.fetch!(entry, "channelUuid"),
      channel_name: Map.get(entry, "channelName"),
      channel_number: Map.get(entry, "channelNumber"),
      title: Map.get(entry, "title") || "Ohne Titel",
      subtitle: Map.get(entry, "subtitle"),
      summary: Map.get(entry, "summary"),
      description: Map.get(entry, "description"),
      starts_at: unix_to_datetime(Map.fetch!(entry, "start")),
      ends_at: unix_to_datetime(Map.fetch!(entry, "stop")),
      next_event_id: Map.get(entry, "nextEventId"),
      image: Map.get(entry, "image") || Map.get(entry, "channelIcon"),
      dvr_uuid: Map.get(entry, "dvrUuid"),
      dvr_state: Map.get(entry, "dvrState")
    }
  end

  @doc """
  True when this programme already has a scheduled or active recording.
  """
  def recording?(%__MODULE__{dvr_state: state}) when is_binary(state) do
    state in ["scheduled", "recording"]
  end

  def recording?(_), do: false

  def now?(programme, now \\ DateTime.utc_now()) do
    DateTime.compare(programme.starts_at, now) != :gt and
      DateTime.compare(programme.ends_at, now) == :gt
  end

  def display_text(%__MODULE__{} = programme) do
    [
      programme.title,
      programme.subtitle,
      programme.summary,
      programme.description
    ]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> case do
      nil -> "Keine Programminformation"
      text -> String.trim(text)
    end
  end

  defp unix_to_datetime(seconds) when is_integer(seconds) do
    DateTime.from_unix!(seconds)
  end
end
