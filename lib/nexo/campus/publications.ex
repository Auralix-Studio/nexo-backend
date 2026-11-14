defmodule Nexo.Campus.Publications do
  @moduledoc """
  University announcements shown on the home screen, from SIGMA
  `Recursos/ListarPublicaciones`. Spanish keys become the contract's, the
  `"1080x1080"` dimension becomes `width`/`height`, and entries without an
  image or video URL are dropped.
  """
  alias Nexo.Upstream.{Normalize, Sessions}

  @doc "`{:ok, publications, meta}` or `{:error, :reauth_required | :unavailable}`."
  def list(subject) do
    with {:ok, data} <- Sessions.sigma_fetch(subject, "/Recursos/ListarPublicaciones") do
      items = for row <- List.wrap(data), is_map(row), item = build(row), do: item
      {:ok, items, %{source: "sigma"}}
    end
  end

  @doc false
  def build(row) do
    url = Normalize.text(row["urlPrincipal"])

    if url do
      {width, height} = dimension(row["dimensionPrincipal"])

      %{
        id: Normalize.int(row["idPublicacion"]),
        kind: row["tipoContenido"] |> Normalize.text() |> kind(),
        url: url,
        adaptive_url: Normalize.text(row["urlAdaptable"]),
        link_url: Normalize.text(row["urlReferencia"]),
        button_text: Normalize.text(row["textoBoton"]),
        downloadable: Normalize.bool(row["permiteDescarga"]),
        width: width,
        height: height
      }
    end
  end

  defp kind(nil), do: "image"
  defp kind(text), do: String.downcase(text)

  defp dimension(value) do
    with t when is_binary(t) <- Normalize.text(value),
         [w, h] <- String.split(t, ~r/\s*[x×]\s*/i),
         w when is_integer(w) <- Normalize.int(w),
         h when is_integer(h) <- Normalize.int(h) do
      {w, h}
    else
      _ -> {nil, nil}
    end
  end
end
