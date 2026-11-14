defmodule Nexo.Web.Api.RouteSpecTest do
  @moduledoc "The route framework itself: specs, params and the routing table. No database."
  use ExUnit.Case, async: true

  alias Nexo.Web.Api.{Params, Registry, Route}

  defp spec(name, method, path),
    do: Route.build_spec!(Demo, name: name, method: method, path: path)

  describe "build_spec!/2" do
    test "adds path parameters as required strings" do
      spec = Route.build_spec!(Demo, name: "demo", method: :get, path: "/items/:code")
      assert spec.segments == [{:literal, "items"}, {:param, :code}]
      assert spec.params == [code: [type: :string, required: true]]
      assert spec.flag == "demo"
      assert spec.attest
    end

    test "rejects malformed specs at compile time" do
      for opts <- [
            [method: :get, path: "/x"],
            [name: "Bad Name", method: :get, path: "/x"],
            [name: "x", method: :fetch, path: "/x"],
            [name: "x", method: :get, path: "x"],
            [name: "x", method: :get, path: "/x", auth: [:root]],
            [name: "x", method: :get, path: "/x", params: [a: [type: :float]]],
            [name: "x", method: :get, path: "/x", params: [a: [format: "("]]],
            [name: "x", method: :get, path: "/x", params: [a: [typo: 1]]],
            [name: "x", method: :get, path: "/x", rate_limit: {0, 60}]
          ] do
        assert_raise ArgumentError, fn -> Route.build_spec!(Demo, opts) end
      end
    end
  end

  describe "Registry" do
    test "refuses two routes that answer the same request" do
      assert_raise ArgumentError, ~r/all answer GET/, fn ->
        Registry.build!([spec("a", :get, "/s/:code"), spec("b", :get, "/s/:id")])
      end
    end

    test "refuses duplicate names" do
      assert_raise ArgumentError, ~r/share the name/, fn ->
        Registry.build!([spec("a", :get, "/a"), spec("a", :post, "/b")])
      end
    end

    test "matches literals before parameters and reports allowed methods" do
      routes =
        Registry.build!([spec("show", :get, "/s/:code"), spec("search", :get, "/s/search")])

      assert {:ok, %{name: "search"}, %{}} = Registry.match(routes, :get, ["s", "search"])
      assert {:ok, %{name: "show"}, %{"code" => "U1"}} = Registry.match(routes, :get, ["s", "U1"])
      assert {:error, {:method_not_allowed, [:get]}} = Registry.match(routes, :post, ["s", "U1"])
      assert {:error, :not_found} = Registry.match(routes, :get, ["s"])
    end
  end

  describe "Params" do
    @schema [
      name: [type: :string, required: true, min: 2, max: 5],
      age: [type: :integer, min: 0, max: 120],
      on: [type: :boolean],
      code: [type: :string, format: "^[A-Z]+$"],
      kind: [type: :string, in: ["a", "b"]]
    ]

    test "coerces, trims and drops undeclared params" do
      assert {:ok, %{name: "Ana", age: 30, on: true}} =
               Params.validate(@schema, %{
                 "name" => "  Ana ",
                 "age" => "30",
                 "on" => "true",
                 "isAdmin" => true
               })
    end

    test "reports every invalid field at once" do
      assert {:error, errors} =
               Params.validate(@schema, %{
                 "age" => "old",
                 "on" => "yes",
                 "code" => "abc",
                 "kind" => "z"
               })

      assert Enum.map(errors, & &1.field) == ~w(name age on code kind)
    end

    test "caps strings without an explicit max" do
      schema = [note: [type: :string]]

      assert {:error, [%{field: "note"}]} =
               Params.validate(schema, %{"note" => String.duplicate("x", 1_001)})
    end
  end
end
