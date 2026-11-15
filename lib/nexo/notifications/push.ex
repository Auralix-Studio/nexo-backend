defmodule Nexo.Notifications.Push do
  @moduledoc """
  Sends a push to every device of a user and drops the tokens FCM reports
  as dead. `grade/2` builds the one message the app receives: a visible
  notification plus `data: {type: "grade", term, course}`.
  """
  alias Nexo.Notifications.{Devices, Fcm}

  @grades_channel "grades"

  def enabled?, do: Fcm.enabled?()

  @doc "Sends `message` (without `token`) to each device of `subject`. Returns how many got it."
  def deliver(subject, message) do
    subject
    |> Devices.tokens()
    |> Enum.count(fn token ->
      case Fcm.send(Map.put(message, :token, token)) do
        :ok ->
          true

        {:error, reason} when reason in [:unregistered, :invalid_argument] ->
          Devices.forget(token)
          false

        {:error, _} ->
          false
      end
    end)
  end

  @doc "A teacher saved a grade: `section` from `Nexo.Teaching.Sections`, `item` `%{value, unit, type}`."
  def grade(section, item) do
    course = section.course
    detail = [item[:unit], item[:type]] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
    body = if detail == "", do: format(item.value), else: "#{detail}: #{format(item.value)}"

    %{
      notification: %{title: "Nueva nota · #{course.name}", body: body},
      data: %{type: "grade", term: to_string(section.term), course: to_string(course.code)},
      android: %{
        priority: "HIGH",
        notification: %{channel_id: @grades_channel, tag: "grade-#{course.code}"}
      }
    }
  end

  @doc false
  def format(value) when is_integer(value), do: Integer.to_string(value)

  def format(value) when is_float(value) do
    if value == Float.round(value),
      do: value |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(value, [:compact, decimals: 2])
  end
end
