defmodule Tvplayer.Tvheadend.ProgrammeTest do
  use ExUnit.Case, async: true

  alias Tvplayer.Tvheadend.Programme

  test "now_and_next picks the current show and the one that follows" do
    now = DateTime.utc_now()

    current = programme(1, DateTime.add(now, -600, :second), DateTime.add(now, 1800, :second))
    upcoming = programme(2, DateTime.add(now, 1800, :second), DateTime.add(now, 5400, :second))
    later = programme(3, DateTime.add(now, 5400, :second), DateTime.add(now, 9000, :second))

    assert %{now: ^current, next: ^upcoming} =
             Programme.now_and_next([later, current, upcoming], now)
  end

  test "now_and_next is nil for next when only the current show is known" do
    now = DateTime.utc_now()
    current = programme(1, DateTime.add(now, -60, :second), DateTime.add(now, 60, :second))

    assert %{now: ^current, next: nil} = Programme.now_and_next([current], now)
  end

  test "now_and_next returns empty slots for no programmes" do
    assert Programme.now_and_next([]) == %{now: nil, next: nil}
  end

  defp programme(event_id, starts_at, ends_at) do
    %Programme{
      event_id: event_id,
      channel_uuid: "ch",
      title: "Show #{event_id}",
      starts_at: starts_at,
      ends_at: ends_at
    }
  end
end
