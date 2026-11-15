defmodule Nexo.Web.Api.Spec do
  @moduledoc "What a route declares about itself. Built at compile time by `Nexo.Web.Api.Route`."

  @enforce_keys [:module, :name, :method, :path, :segments]
  defstruct [
    :module,
    :name,
    :method,
    :path,
    :segments,
    description: "",
    auth: :public,
    params: [],
    attest: true,
    rate_limit: nil,
    param_rate_limit: nil,
    flag: nil,
    tags: [],
    scopes: []
  ]

  @type segment :: {:literal, String.t()} | {:param, atom()}
  @type t :: %__MODULE__{
          module: module(),
          name: String.t(),
          method: :get | :post | :put | :patch | :delete,
          path: String.t(),
          segments: [segment()],
          description: String.t(),
          auth: :public | :admin | :integration | [:teacher | :student | :guardian],
          params: keyword(keyword()),
          attest: boolean(),
          rate_limit: nil | {pos_integer(), pos_integer()},
          param_rate_limit: nil | {atom(), pos_integer(), pos_integer()},
          flag: String.t() | nil,
          tags: [String.t()],
          scopes: [String.t()]
        }
end
