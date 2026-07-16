defmodule Tvplayer.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  Currently unused — the app has no database in v1.
  Kept as a stub for when Ecto is re-enabled.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Tvplayer.DataCase
    end
  end

  setup _tags do
    :ok
  end
end
