defmodule Nexo.Integrations.Calendar do
  @moduledoc """
  A private calendar subscription with the student's weekly schedule.

  The student turns it on in the app and gets a secret URL
  (`/calendar/<key>.ics`) that any calendar app can subscribe to: Google
  Calendar, Outlook, Apple Calendar or a routine planner. Only the key's hash
  is stored; turning it on again rotates the key, so a leaked URL is revoked
  by generating a new one.

  The feed is built from `Nexo.Integrations.SharedData`: one weekly
  recurring event per class, in Lima time, repeated until the end of the
  term.
  """
  alias Nexo.Infra.Db
  alias Nexo.Integrations.{SharedData, Tokens}
  alias Nexo.Security.Audit

  @collection "calendar_feeds"
  @default_term_weeks 17
  @byday %{1 => "MO", 2 => "TU", 3 => "WE", 4 => "TH", 5 => "FR", 6 => "SA", 7 => "SU"}

  @doc "Creates or rotates the feed key. Returns the raw key, shown only once."
  def enable(student_id, meta \\ %{}) when is_binary(student_id) do
    key = Tokens.generate()
    now = Db.now()

    {:ok, _} =
      Mongo.update_one(
        Db.conn(),
        @collection,
        %{student_id: student_id},
        %{
          "$set" => %{key_hash: Tokens.hash(key), rotated_at: now},
          "$setOnInsert" => %{created_at: now}
        },
        upsert: true
      )

    Audit.log(:calendar_feed_enabled, Map.merge(meta, %{actor_id: student_id}))
    {:ok, key}
  end

  def disable(student_id, meta \\ %{}) when is_binary(student_id) do
    Mongo.delete_one(Db.conn(), @collection, %{student_id: student_id})
    Audit.log(:calendar_feed_disabled, Map.merge(meta, %{actor_id: student_id}))
    :ok
  end

  def enabled?(student_id),
    do: Mongo.find_one(Db.conn(), @collection, %{student_id: student_id}) != nil

  @doc "The calendar for a feed key, or `:not_found`."
  def render(key) when is_binary(key) do
    with %{"student_id" => student_id} <-
           Mongo.find_one(Db.conn(), @collection, %{key_hash: Tokens.hash(key)}),
         {:ok, shared} <- SharedData.get(student_id) do
      Mongo.update_one(Db.conn(), @collection, %{student_id: student_id}, %{
        "$set" => %{last_fetched_at: Db.now()}
      })

      {:ok, to_ics(shared, student_id)}
    else
      _ -> :not_found
    end
  end

  # --- iCalendar (RFC 5545) -----------------------------------------------------

  @doc false
  def to_ics(shared, uid_seed, today \\ Date.utc_today()) do
    schedule = shared["schedule"] || %{}
    {term_start, term_end} = term_range(schedule["term"] || %{}, today)
    stamp = DateTime.utc_now() |> format_utc()

    events =
      for class <- schedule["classes"] || [] do
        event(class, term_start, term_end, stamp, uid_seed)
      end

    ([
       "BEGIN:VCALENDAR",
       "VERSION:2.0",
       "PRODID:-//Auralix//Nexo//ES",
       "CALSCALE:GREGORIAN",
       "METHOD:PUBLISH",
       "X-WR-CALNAME:Nexo · Horario",
       "X-WR-TIMEZONE:America/Lima",
       "REFRESH-INTERVAL;VALUE=DURATION:PT6H",
       "X-PUBLISHED-TTL:PT6H",
       "BEGIN:VTIMEZONE",
       "TZID:America/Lima",
       "BEGIN:STANDARD",
       "DTSTART:19700101T000000",
       "TZOFFSETFROM:-0500",
       "TZOFFSETTO:-0500",
       "TZNAME:-05",
       "END:STANDARD",
       "END:VTIMEZONE"
     ] ++ List.flatten(events) ++ ["END:VCALENDAR"])
    |> Enum.map_join("", &(fold(&1) <> "\r\n"))
  end

  defp event(class, term_start, term_end, stamp, uid_seed) do
    first = first_on_weekday(term_start, class["weekday"])
    location = class["room"]

    description =
      [class["section"] && "Sección #{class["section"]}", class["teacher"], class["modality"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    uid =
      Tokens.hash("#{uid_seed}|#{class["course"]}|#{class["weekday"]}|#{class["start"]}")
      |> binary_part(0, 32)

    [
      "BEGIN:VEVENT",
      "UID:#{uid}@nexo.aurx.pro",
      "DTSTAMP:#{stamp}",
      "DTSTART;TZID=America/Lima:#{local(first, class["start"])}",
      "DTEND;TZID=America/Lima:#{local(first, class["end"])}",
      "RRULE:FREQ=WEEKLY;BYDAY=#{@byday[class["weekday"]]};UNTIL=#{until(term_end)}",
      "SUMMARY:#{escape(class["course"])}"
    ] ++
      if(location, do: ["LOCATION:#{escape(location)}"], else: []) ++
      if(description != "", do: ["DESCRIPTION:#{escape(description)}"], else: []) ++
      ["END:VEVENT"]
  end

  defp term_range(term, today) do
    start = parse_date(term["start"]) || Date.beginning_of_week(today)
    finish = parse_date(term["end"]) || Date.add(start, @default_term_weeks * 7)
    {start, finish}
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp first_on_weekday(start, weekday) do
    Date.add(start, rem(weekday - Date.day_of_week(start) + 7, 7))
  end

  defp local(date, hh_mm) do
    [h, m] = String.split(hh_mm, ":")
    Calendar.strftime(date, "%Y%m%d") <> "T" <> h <> m <> "00"
  end

  # End of the term's last day in Lima (UTC-5, no daylight saving), in UTC.
  defp until(date), do: Calendar.strftime(Date.add(date, 1), "%Y%m%d") <> "T045959Z"

  defp format_utc(datetime), do: Calendar.strftime(datetime, "%Y%m%dT%H%M%SZ")

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace(~r/\r?\n/, "\\n")
  end

  # Lines longer than 75 octets continue on the next line after a space,
  # cutting only between UTF-8 characters.
  defp fold(line) when byte_size(line) <= 75, do: line

  defp fold(line) do
    {chunks, current} =
      line
      |> String.graphemes()
      |> Enum.reduce({[], ""}, fn char, {chunks, current} ->
        limit = if chunks == [], do: 75, else: 74

        if byte_size(current) + byte_size(char) > limit,
          do: {[current | chunks], char},
          else: {chunks, current <> char}
      end)

    [current | chunks] |> Enum.reverse() |> Enum.join("\r\n ")
  end
end
