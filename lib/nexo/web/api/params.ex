defmodule Nexo.Web.Api.Params do
  @moduledoc """
  Whitelist validation and coercion of request params.

  Only declared params come out, with atom keys; everything else is
  dropped. Every error is reported at once, so the app can mark all the
  wrong fields in one go.

  Rules: `type` (`:string` | `:integer` | `:boolean`), `required`, `min` /
  `max` (length for strings, value for integers), `format` (regex source)
  and `in` (allowed values). Strings are trimmed and capped at
  #{1_000} characters unless `max` says otherwise.
  """

  @default_max_string 1_000

  @spec validate(keyword(keyword()), map()) ::
          {:ok, map()} | {:error, [%{field: String.t(), reason: String.t()}]}
  def validate(schema, raw) when is_map(raw) do
    {values, errors} =
      Enum.reduce(schema, {%{}, []}, fn {name, rules}, {values, errors} ->
        case Map.fetch(raw, Atom.to_string(name)) do
          {:ok, value} when value not in [nil, ""] ->
            case coerce(value, rules) do
              {:ok, coerced} -> {Map.put(values, name, coerced), errors}
              {:error, reason} -> {values, [error(name, reason) | errors]}
            end

          _missing ->
            if Keyword.get(rules, :required, false),
              do: {values, [error(name, "is required") | errors]},
              else: {values, errors}
        end
      end)

    if errors == [], do: {:ok, values}, else: {:error, Enum.reverse(errors)}
  end

  defp error(name, reason), do: %{field: Atom.to_string(name), reason: reason}

  defp coerce(value, rules) do
    with {:ok, typed} <- cast(Keyword.fetch!(rules, :type), value),
         :ok <- check_bounds(typed, rules),
         :ok <- check_format(typed, rules),
         :ok <- check_in(typed, rules) do
      {:ok, typed}
    end
  end

  defp cast(:string, value) when is_binary(value) do
    if String.valid?(value), do: {:ok, String.trim(value)}, else: {:error, "must be valid UTF-8"}
  end

  defp cast(:integer, value) when is_integer(value), do: {:ok, value}

  defp cast(:integer, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "must be an integer"}
    end
  end

  defp cast(:boolean, value) when is_boolean(value), do: {:ok, value}
  defp cast(:boolean, "true"), do: {:ok, true}
  defp cast(:boolean, "false"), do: {:ok, false}

  # Objects and lists pass through as JSON; the route validates their content.
  defp cast(:map, value) when is_map(value), do: {:ok, value}
  defp cast(:list, value) when is_list(value), do: {:ok, value}

  defp cast(type, _value), do: {:error, "must be a #{type}"}

  defp check_bounds(value, rules) when is_binary(value) do
    length = String.length(value)
    max = Keyword.get(rules, :max, @default_max_string)

    cond do
      (min = Keyword.get(rules, :min)) && length < min ->
        {:error, "must have at least #{min} characters"}

      length > max ->
        {:error, "must have at most #{max} characters"}

      true ->
        :ok
    end
  end

  defp check_bounds(value, rules) when is_integer(value) do
    cond do
      (min = Keyword.get(rules, :min)) && value < min -> {:error, "must be at least #{min}"}
      (max = Keyword.get(rules, :max)) && value > max -> {:error, "must be at most #{max}"}
      true -> :ok
    end
  end

  defp check_bounds(_value, _rules), do: :ok

  defp check_format(value, rules) when is_binary(value) do
    case Keyword.get(rules, :format) do
      nil ->
        :ok

      source ->
        if Regex.match?(Regex.compile!(source), value),
          do: :ok,
          else: {:error, "has an invalid format"}
    end
  end

  defp check_format(_value, _rules), do: :ok

  defp check_in(value, rules) do
    case Keyword.get(rules, :in) do
      nil ->
        :ok

      allowed ->
        if value in allowed, do: :ok, else: {:error, "must be one of #{Enum.join(allowed, ", ")}"}
    end
  end
end
