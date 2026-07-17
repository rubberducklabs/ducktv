defmodule TvplayerWeb.SharedRecordingLive do
  use TvplayerWeb, :live_view

  alias Tvplayer.Recordings.{ShareLink, Transcoder}
  alias Tvplayer.Tvheadend.{Cache, Recording}

  @timezone "Europe/Vienna"

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case load_shared(token) do
      {:ok, recording} ->
        {:ok,
         assign(socket,
           page_title: recording.title,
           token: token,
           recording: recording,
           error: nil
         )}

      {:error, message} ->
        {:ok,
         assign(socket,
           page_title: "Freigabe",
           token: token,
           recording: nil,
           error: message
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="tv-share-shell">
      <%= if @recording do %>
        <section class="tv-share-player" aria-label="Aufnahme abspielen">
          <div
            id={"shared-cinema-#{@recording.uuid}"}
            class="tv-cinema-stage tv-share-stage"
            phx-hook="RecordingPlayer"
            phx-update="ignore"
            tabindex="0"
            role="region"
            aria-label="Aufnahme abspielen"
          >
            <video
              id={"shared-video-#{@recording.uuid}"}
              class="tv-cinema-video"
              playsinline
              preload="metadata"
              src={~p"/share/#{@token}/media"}
            ></video>

            <div class="tv-player-ui" data-player-ui>
              <div class="tv-cinema-top is-visible" data-top-chrome>
                <div class="tv-cinema-meta">
                  <p class="tv-cinema-eyebrow">Aufnahme</p>
                  <h1 id="shared-recording-title" class="tv-cinema-title">
                    {@recording.title}
                  </h1>
                  <p :if={@recording.subtitle} class="tv-cinema-subtitle">
                    {@recording.subtitle}
                  </p>
                  <div class="tv-cinema-details">
                    <span class="tv-cinema-channel">
                      {@recording.channel_name || "Kanal"}
                    </span>
                    <span class="tv-cinema-dot" aria-hidden="true">·</span>
                    <span>{format_time_range(@recording.starts_at, @recording.ends_at)}</span>
                  </div>
                </div>
              </div>

              <button
                type="button"
                class="tv-player-big-play"
                data-big-play
                hidden
                aria-label="Abspielen"
              >
                <span class="hero-play-solid size-12"></span>
              </button>

              <div class="tv-player-chrome is-visible" data-chrome>
                <div class="tv-player-progress">
                  <label class="sr-only" for={"shared-seek-#{@recording.uuid}"}>Position</label>
                  <input
                    id={"shared-seek-#{@recording.uuid}"}
                    class="tv-player-seek"
                    type="range"
                    min="0"
                    max="1"
                    step="0.001"
                    value="0"
                    data-seek
                    aria-label="Wiedergabeposition"
                  />
                  <div class="tv-player-time">
                    <span data-current-time>0:00</span>
                    <span class="tv-player-time-sep" aria-hidden="true">/</span>
                    <span data-duration>0:00</span>
                  </div>
                </div>

                <div class="tv-player-chrome-bar">
                  <button
                    type="button"
                    class="tv-player-ctrl"
                    data-play-pause
                    aria-label="Abspielen"
                  >
                    <span class="hero-play-solid size-7" data-icon-play></span>
                    <span class="hero-pause-solid size-7" data-icon-pause hidden></span>
                  </button>

                  <button
                    type="button"
                    class="tv-player-ctrl tv-player-skip"
                    data-skip-back
                    aria-label="10 Sekunden zurück"
                  >
                    <span class="tv-player-skip-label">−10</span>
                  </button>

                  <button
                    type="button"
                    class="tv-player-ctrl tv-player-skip"
                    data-skip-forward
                    aria-label="10 Sekunden vor"
                  >
                    <span class="tv-player-skip-label">+10</span>
                  </button>

                  <div class="tv-player-volume">
                    <button
                      type="button"
                      class="tv-player-ctrl"
                      data-mute
                      aria-label="Stummschalten"
                    >
                      <span class="hero-speaker-wave-solid size-6" data-icon-unmuted></span>
                      <span class="hero-speaker-x-mark-solid size-6" data-icon-muted hidden></span>
                    </button>
                    <label class="sr-only" for={"shared-volume-#{@recording.uuid}"}>
                      Lautstärke
                    </label>
                    <input
                      id={"shared-volume-#{@recording.uuid}"}
                      class="tv-player-volume-slider"
                      type="range"
                      min="0"
                      max="1"
                      step="0.05"
                      value="1"
                      data-volume
                      aria-label="Lautstärke"
                    />
                  </div>

                  <a
                    id="share-download-btn"
                    href={~p"/share/#{@token}/download"}
                    class="tv-player-download"
                    download={web_download_filename(@recording)}
                    aria-label="Herunterladen"
                    title="Herunterladen"
                  >
                    <span class="hero-arrow-down-tray-solid size-5"></span>
                    <span>Download</span>
                  </a>

                  <button
                    type="button"
                    class="tv-player-ctrl tv-player-fullscreen"
                    data-fullscreen
                    aria-label="Vollbild"
                  >
                    <span class="hero-arrows-pointing-out-solid size-6" data-icon-fs-enter></span>
                    <span class="hero-arrows-pointing-in-solid size-6" data-icon-fs-exit hidden></span>
                  </button>
                </div>
              </div>
            </div>
          </div>
        </section>
      <% else %>
        <div id="share-error" class="tv-share-error" role="alert">
          <p class="tv-brand">TV Player</p>
          <h1 class="tv-title">Freigabe nicht verfügbar</h1>
          <p class="tv-share-error-text">{@error}</p>
        </div>
      <% end %>

      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  defp load_shared(token) do
    with {:ok, uuid} <- ShareLink.verify(token),
         %Recording{} = recording <- Cache.recording(uuid),
         true <- Recording.downloadable?(recording),
         true <- File.exists?(Transcoder.output_path(uuid)) do
      {:ok, recording}
    else
      {:error, :expired} ->
        {:error, "Dieser Freigabelink ist abgelaufen."}

      {:error, _} ->
        {:error, "Dieser Freigabelink ist ungültig."}

      nil ->
        {:error, "Die Aufnahme wurde nicht gefunden."}

      false ->
        {:error, "Die Web-Version dieser Aufnahme ist nicht verfügbar."}
    end
  end

  defp web_download_filename(recording), do: Recording.web_download_filename(recording)

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!(@timezone)
    |> Calendar.strftime("%H:%M")
  end

  defp format_datetime(%DateTime{} = dt) do
    local = DateTime.shift_zone!(dt, @timezone)
    weekday = Enum.at(~w(Mo Di Mi Do Fr Sa So), Date.day_of_week(DateTime.to_date(local)) - 1)
    "#{weekday} #{Calendar.strftime(local, "%d.%m. %H:%M")}"
  end

  defp format_time_range(%DateTime{} = starts_at, %DateTime{} = ends_at) do
    start_local = DateTime.shift_zone!(starts_at, @timezone)
    end_local = DateTime.shift_zone!(ends_at, @timezone)

    end_str =
      if Date.compare(DateTime.to_date(start_local), DateTime.to_date(end_local)) == :eq do
        format_time(ends_at)
      else
        Calendar.strftime(end_local, "%d.%m. %H:%M")
      end

    "#{format_datetime(starts_at)} – #{end_str}"
  end
end
