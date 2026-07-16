defmodule Tvplayer.Repo do
  @moduledoc """
  Ecto repo scaffolding (unused in v1).

  The app does not start this process. Re-enable by adding it to
  `Tvplayer.Application`, setting `ecto_repos: [Tvplayer.Repo]`, and
  configuring the database in `config/*.exs` / `runtime.exs`.
  """

  use Ecto.Repo,
    otp_app: :tvplayer,
    adapter: Ecto.Adapters.Postgres
end
