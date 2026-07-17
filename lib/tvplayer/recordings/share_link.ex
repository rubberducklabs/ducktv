defmodule Tvplayer.Recordings.ShareLink do
  @moduledoc """
  Signed, database-free share links for recording web versions.

  Tokens encode only the recording UUID and are verified with the endpoint
  secret. Revocation is implicit: delete the recording or its web file, or
  rotate `SECRET_KEY_BASE`.
  """

  @salt "tvplayer.recording.share"
  # Long-lived by design — access ends when the recording/web file is gone.
  @default_max_age 365 * 24 * 60 * 60

  @doc """
  Signs a share token for the given recording UUID.
  """
  def sign(uuid) when is_binary(uuid) and uuid != "" do
    Phoenix.Token.sign(TvplayerWeb.Endpoint, @salt, %{"u" => uuid})
  end

  @doc """
  Verifies a share token and returns `{:ok, uuid}` or `{:error, reason}`.
  """
  def verify(token) when is_binary(token) and token != "" do
    case Phoenix.Token.verify(TvplayerWeb.Endpoint, @salt, token, max_age: max_age()) do
      {:ok, %{"u" => uuid}} when is_binary(uuid) and uuid != "" ->
        {:ok, uuid}

      {:ok, _} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify(_), do: {:error, :invalid}

  @doc """
  Absolute share URL for a recording UUID.
  """
  def url_for(uuid) when is_binary(uuid) do
    token = sign(uuid)
    "#{TvplayerWeb.Endpoint.url()}/share/#{token}"
  end

  @doc """
  Human-readable validity hint for the share UI.
  """
  def validity_label do
    days = div(max_age(), 24 * 60 * 60)

    cond do
      days >= 365 -> "etwa #{div(days, 365)} Jahr(e)"
      days >= 30 -> "etwa #{div(days, 30)} Monat(e)"
      true -> "#{days} Tag(e)"
    end
  end

  defp max_age do
    Application.get_env(:tvplayer, :share_link_max_age, @default_max_age)
  end
end
