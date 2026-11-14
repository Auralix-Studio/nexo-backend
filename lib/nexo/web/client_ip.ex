defmodule Nexo.Web.ClientIp do
  @moduledoc """
  The real client IP.

  The API always sits behind a proxy (Azure Container Apps ingress, or a
  Cloudflare tunnel), so the direct peer is the proxy and the client's
  address travels in a header. Headers are only believed when the direct
  peer is a trusted proxy (`:trusted_proxies`, IPs or CIDR ranges); anyone
  else could write them to dodge rate limits or forge audit entries.

    * `cf-connecting-ip` is set by Cloudflare itself and used as is.
    * `x-forwarded-for` is read from the right: each proxy appends the peer
      it saw, so the rightmost address that is not a trusted proxy is the
      client. The leftmost entries are whatever the client sent and are
      never trusted.
  """
  import Plug.Conn
  import Bitwise

  @default_trusted ["127.0.0.1", "::1"]

  @spec get(Plug.Conn.t()) :: String.t()
  def get(conn) do
    trusted = trusted_ranges()

    if trusted?(conn.remote_ip, trusted) do
      header_ip(conn, "cf-connecting-ip") || from_forwarded_for(conn, trusted) ||
        format(conn.remote_ip)
    else
      format(conn.remote_ip)
    end
  end

  defp from_forwarded_for(conn, trusted) do
    conn
    |> get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&parse/1)
    |> Enum.reverse()
    |> Enum.find(fn address -> address != nil and not trusted?(address, trusted) end)
    |> case do
      nil -> nil
      address -> format(address)
    end
  end

  defp header_ip(conn, header) do
    with [value | _] <- get_req_header(conn, header),
         address when address != nil <- parse(value) do
      format(address)
    else
      _ -> nil
    end
  end

  defp parse(value) do
    case value |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      {:ok, address} -> address
      {:error, _} -> nil
    end
  end

  # --- Trusted ranges ---------------------------------------------------------

  defp trusted_ranges do
    :nexo
    |> Application.get_env(:trusted_proxies, @default_trusted)
    |> Enum.flat_map(fn entry ->
      case parse_range(entry) do
        nil -> []
        range -> [range]
      end
    end)
  end

  @doc false
  def parse_range(entry) when is_binary(entry) do
    {ip, bits} =
      case String.split(String.trim(entry), "/", parts: 2) do
        [ip, bits] -> {ip, Integer.parse(bits)}
        [ip] -> {ip, :full}
      end

    case parse(ip) do
      nil ->
        nil

      address ->
        size = bit_size_of(address)

        case bits do
          :full -> {to_int(address), size, size}
          {n, ""} when n >= 0 and n <= size -> {to_int(address), n, size}
          _ -> nil
        end
    end
  end

  defp trusted?(address, ranges) do
    value = to_int(address)
    size = bit_size_of(address)

    Enum.any?(ranges, fn {network, bits, range_size} ->
      range_size == size and bsr(value, size - bits) == bsr(network, size - bits)
    end)
  end

  defp bit_size_of(address) when tuple_size(address) == 4, do: 32
  defp bit_size_of(_address), do: 128

  defp to_int({a, b, c, d}), do: bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d

  defp to_int({_, _, _, _, _, _, _, _} = address) do
    address |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> bsl(acc, 16) + part end)
  end

  defp format(address), do: address |> :inet.ntoa() |> to_string()
end
