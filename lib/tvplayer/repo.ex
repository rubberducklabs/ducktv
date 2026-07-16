defmodule Tvplayer.Repo do
  use Ecto.Repo,
    otp_app: :tvplayer,
    adapter: Ecto.Adapters.Postgres
end
