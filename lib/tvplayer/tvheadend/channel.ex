defmodule Tvplayer.Tvheadend.Channel do
  @moduledoc """
  Normalized TVHeadend channel representation.
  """

  @enforce_keys [:uuid, :name, :number, :enabled]
  defstruct [
    :uuid,
    :name,
    :number,
    :enabled,
    :icon_path,
    :tags,
    :services
  ]

  @type t :: %__MODULE__{
          uuid: String.t(),
          name: String.t(),
          number: non_neg_integer() | nil,
          enabled: boolean(),
          icon_path: String.t() | nil,
          tags: [String.t()],
          services: [String.t()]
        }

  def from_api(entry) when is_map(entry) do
    %__MODULE__{
      uuid: Map.fetch!(entry, "uuid"),
      name: Map.get(entry, "name") || "Unbekannt",
      number: parse_number(Map.get(entry, "number")),
      enabled: Map.get(entry, "enabled", true) == true,
      icon_path: Map.get(entry, "icon_public_url"),
      tags: List.wrap(Map.get(entry, "tags", [])),
      services: List.wrap(Map.get(entry, "services", []))
    }
  end

  defp parse_number(nil), do: nil
  defp parse_number(number) when is_integer(number), do: number

  defp parse_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp parse_number(_), do: nil
end
