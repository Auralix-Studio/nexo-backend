defmodule Nexo.Integrations.SharedData do
  @moduledoc """
  What a student chose to share with integrations: a short profile and the
  weekly schedule, stored encrypted (`Nexo.Security.Vault`) in
  `integration_data`, one document per student.

  The app uploads it only after the student turns an integration on, and
  sends it again when the schedule changes. Turning sharing off deletes the
  document, which also empties the calendar feed and every connected app.

  Shapes after normalization (string keys, as stored and served):

      profile:  code, name, first_name, last_name, career, faculty, cycle
      schedule: %{"term" => %{"name", "start", "end"},
                  "classes" => [%{"course", "section", "weekday", "start",
                                  "end", "room", "teacher", "modality"}]}

  Weekdays are ISO (1 = Monday … 7 = Sunday); times are `HH:MM` in Lima time;
  term dates are ISO dates.
  """
  alias Nexo.Infra.Db
  alias Nexo.Security.Vault

  @collection "integration_data"
  @max_classes 80
  @max_text 120
  @profile_fields ~w(code name first_name last_name career faculty cycle)
  @class_text ~w(course section room teacher modality)

  @doc "Validates and stores the shared data. Returns `{:error, details}` when invalid."
  def put(student_id, payload) when is_binary(student_id) and is_map(payload) do
    with {:ok, profile} <- normalize_profile(payload["profile"]),
         {:ok, schedule} <- normalize_schedule(payload["schedule"]) do
      data = %{"profile" => profile, "schedule" => schedule}
      now = Db.now()

      {:ok, _} =
        Mongo.update_one(
          Db.conn(),
          @collection,
          %{student_id: student_id},
          %{
            "$set" => %{
              payload: %BSON.Binary{binary: Vault.encrypt(Jason.encode!(data))},
              updated_at: now
            },
            "$setOnInsert" => %{inserted_at: now}
          },
          upsert: true
        )

      {:ok, Map.put(data, "updated_at", now)}
    end
  end

  @doc "The student's shared data, or `:none`."
  def get(student_id) when is_binary(student_id) do
    with %{"payload" => %BSON.Binary{binary: blob}} = doc <-
           Mongo.find_one(Db.conn(), @collection, %{student_id: student_id}),
         {:ok, json} <- Vault.decrypt(blob),
         {:ok, data} <- Jason.decode(json) do
      {:ok, Map.put(data, "updated_at", doc["updated_at"])}
    else
      _ -> :none
    end
  end

  def delete(student_id) when is_binary(student_id) do
    Mongo.delete_one(Db.conn(), @collection, %{student_id: student_id})
    :ok
  end

  # --- Normalization ----------------------------------------------------------

  defp normalize_profile(nil), do: {:ok, %{}}

  defp normalize_profile(%{} = profile) do
    Enum.reduce_while(@profile_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case text(profile[field]) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        :error -> {:halt, {:error, [%{field: "profile.#{field}", reason: "is not valid text"}]}}
      end
    end)
  end

  defp normalize_profile(_), do: {:error, [%{field: "profile", reason: "must be an object"}]}

  defp normalize_schedule(nil), do: {:ok, %{"term" => %{}, "classes" => []}}

  defp normalize_schedule(%{} = schedule) do
    with {:ok, term} <- normalize_term(schedule["term"]),
         {:ok, classes} <- normalize_classes(schedule["classes"]) do
      {:ok, %{"term" => term, "classes" => classes}}
    end
  end

  defp normalize_schedule(_), do: {:error, [%{field: "schedule", reason: "must be an object"}]}

  defp normalize_term(nil), do: {:ok, %{}}

  defp normalize_term(%{} = term) do
    with {:ok, name} <- text(term["name"]),
         {:ok, start} <- date(term["start"]),
         {:ok, finish} <- date(term["end"]) do
      if start && finish && Date.compare(start, finish) == :gt do
        {:error, [%{field: "schedule.term", reason: "ends before it starts"}]}
      else
        {:ok,
         %{"name" => name, "start" => iso(start), "end" => iso(finish)}
         |> Map.reject(fn {_, v} -> is_nil(v) end)}
      end
    else
      _ -> {:error, [%{field: "schedule.term", reason: "is not valid"}]}
    end
  end

  defp normalize_term(_), do: {:error, [%{field: "schedule.term", reason: "must be an object"}]}

  defp normalize_classes(nil), do: {:ok, []}

  defp normalize_classes(classes) when is_list(classes) and length(classes) <= @max_classes do
    classes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {class, index}, {:ok, acc} ->
      case normalize_class(class) do
        {:ok, normalized} ->
          {:cont, {:ok, [normalized | acc]}}

        :error ->
          {:halt, {:error, [%{field: "schedule.classes.#{index}", reason: "is not valid"}]}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp normalize_classes(_),
    do:
      {:error,
       [%{field: "schedule.classes", reason: "must be a list of at most #{@max_classes}"}]}

  defp normalize_class(%{} = class) do
    with {:ok, course} when is_binary(course) <- text(class["course"]),
         weekday when weekday in 1..7 <- class["weekday"],
         {:ok, start} <- time(class["start"]),
         {:ok, finish} <- time(class["end"]),
         true <- start < finish,
         {:ok, extra} <- extra_text(class) do
      {:ok,
       Map.merge(extra, %{
         "course" => course,
         "weekday" => weekday,
         "start" => start,
         "end" => finish
       })}
    else
      _ -> :error
    end
  end

  defp normalize_class(_), do: :error

  defp extra_text(class) do
    Enum.reduce_while(@class_text -- ["course"], {:ok, %{}}, fn field, {:ok, acc} ->
      case text(class[field]) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp text(nil), do: {:ok, nil}

  defp text(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      not String.valid?(trimmed) -> :error
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > @max_text -> :error
      true -> {:ok, trimmed}
    end
  end

  defp text(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp text(_), do: :error

  defp time(value) when is_binary(value) do
    case Regex.run(~r/^([01]\d|2[0-3]):([0-5]\d)$/, value) do
      [hm | _] -> {:ok, hm}
      nil -> :error
    end
  end

  defp time(_), do: :error

  defp date(nil), do: {:ok, nil}

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp date(_), do: :error

  defp iso(nil), do: nil
  defp iso(date), do: Date.to_iso8601(date)
end
