defmodule Tvplayer.Recordings.LocalFileTest do
  use ExUnit.Case, async: false

  alias Tvplayer.Recordings.LocalFile
  alias Tvplayer.Tvheadend.Recording

  setup do
    root =
      Path.join(System.tmp_dir!(), "tvplayer-local-file-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "Show"))
    File.write!(Path.join([root, "Show", "Episode.ts"]), "ts")

    previous = Application.get_env(:tvplayer, :recording_files)

    on_exit(fn ->
      Application.put_env(:tvplayer, :recording_files, previous || [])
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp recording(filename) do
    struct!(Recording,
      uuid: "rec",
      title: "Episode",
      starts_at: ~U[2026-10-19 20:15:00Z],
      ends_at: ~U[2026-10-19 22:00:00Z],
      state: :completed,
      filename: filename
    )
  end

  defp configure(opts), do: Application.put_env(:tvplayer, :recording_files, opts)

  test "maps the TVHeadend path prefix onto the local mount", %{root: root} do
    configure(local_root: root, tvheadend_root: "/recordings")

    assert LocalFile.path(recording("/recordings/Show/Episode.ts")) ==
             {:ok, Path.join([root, "Show", "Episode.ts"])}
  end

  test "uses the local root as the TVHeadend root by default", %{root: root} do
    configure(local_root: root)

    assert {:ok, _} =
             LocalFile.path(recording(Path.join([root, "Show", "Episode.ts"])))
  end

  test "is disabled without a local root" do
    configure([])

    assert LocalFile.path(recording("/recordings/Show/Episode.ts")) == :error
  end

  test "rejects files outside the mount or missing on disk", %{root: root} do
    configure(local_root: root, tvheadend_root: "/recordings")

    assert LocalFile.path(recording("/other/Show/Episode.ts")) == :error
    assert LocalFile.path(recording("/recordings/../etc/passwd")) == :error
    assert LocalFile.path(recording("/recordings/Show/Missing.ts")) == :error
    assert LocalFile.path(recording(nil)) == :error
  end
end
