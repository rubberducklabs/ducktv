defmodule Tvplayer.Tvheadend.RecordingTest do
  use ExUnit.Case, async: true

  alias Tvplayer.Tvheadend.Recording

  test "from_api maps scheduled entry" do
    recording =
      Recording.from_api(%{
        "uuid" => "rec-1",
        "disp_title" => "Tatort",
        "channel" => "ch-1",
        "channelname" => "ORF 1",
        "start" => 1_700_000_000,
        "stop" => 1_700_003_600,
        "start_extra" => 5,
        "stop_extra" => 10,
        "sched_status" => "scheduled",
        "status" => "Scheduled for recording",
        "broadcast" => 42
      })

    assert recording.uuid == "rec-1"
    assert recording.title == "Tatort"
    assert recording.state == :scheduled
    assert recording.start_extra == 5
    assert recording.stop_extra == 10
    assert recording.event_id == 42
    assert Recording.active?(recording)
    assert Recording.state_label(:scheduled) == "Geplant"
  end

  test "from_api derives failed state for real recording errors" do
    recording =
      Recording.from_api(%{
        "uuid" => "rec-2",
        "disp_title" => "News",
        "start" => 1_700_000_000,
        "stop" => 1_700_003_600,
        "sched_status" => "completedError",
        "status" => "Too many data errors",
        "fileremoved" => 0
      })

    assert recording.state == :failed
    assert Recording.state_label(:failed) == "Fehlgeschlagen"
  end

  test "File missing entries are removed (Gelöscht), not failed" do
    # Matches TVheadend's "Gelöschte Aufnahmen" tab: sched_status is often
    # completedError, but status is "File missing" / fileremoved may be set.
    recording =
      Recording.from_api(%{
        "uuid" => "rec-removed",
        "disp_title" => "nano",
        "channelname" => "3sat HD",
        "start" => 1_700_000_000,
        "stop" => 1_700_003_600,
        "sched_status" => "completedError",
        "status" => "File missing",
        "fileremoved" => 0,
        "filesize" => 0
      })

    assert recording.state == :removed
    assert Recording.state_label(:removed) == "Gelöscht"
  end

  test "fileremoved flag maps to removed even without File missing status" do
    recording =
      Recording.from_api(%{
        "uuid" => "rec-deleted",
        "disp_title" => "Deleted Show",
        "start" => 1_700_000_000,
        "stop" => 1_700_003_600,
        "sched_status" => "completed",
        "status" => "Completed OK",
        "fileremoved" => 1
      })

    assert recording.state == :removed
    assert recording.file_removed
  end

  test "downloadable? is true for completed recordings with a file" do
    recording =
      Recording.from_api(%{
        "uuid" => "rec-ok",
        "disp_title" => "Tatort",
        "start" => 1_700_000_000,
        "stop" => 1_700_003_600,
        "sched_status" => "completed",
        "status" => "Completed OK",
        "filesize" => 1_000_000,
        "url" => "dvrfile/rec-ok",
        "filename" => "/video/Tatort.ts"
      })

    assert Recording.downloadable?(recording)
    assert Recording.dvrfile_path(recording) == "/dvrfile/rec-ok"
    assert Recording.download_filename(recording) == "Tatort.ts"
    assert Recording.web_download_filename(recording) == "Tatort.mp4"
  end

  test "downloadable? is false for removed or scheduled recordings" do
    removed =
      Recording.from_api(%{
        "uuid" => "rec-x",
        "disp_title" => "X",
        "start" => 1,
        "stop" => 2,
        "sched_status" => "completedError",
        "status" => "File missing"
      })

    refute Recording.downloadable?(removed)
  end
end
