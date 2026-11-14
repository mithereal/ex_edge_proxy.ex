defmodule EdgeProxy.HTTP.Forwarder do
  @moduledoc """
  Forwards HTTP requests to upstream Phoenix endpoints via Mint.
  """

  import Plug.Conn
  require Logger

  @hop_by_hop_headers MapSet.new([
                        "connection",
                        "keep-alive",
                        "proxy-authenticate",
                        "proxy-authorization",
                        "te",
                        "trailers",
                        "transfer-encoding",
                        "upgrade"
                      ])

  def forward(conn, %{upstream: upstream} = route) do
    with {:ok, body, conn} <- read_full_body(conn, []),
         {:ok, mint_conn} <- Mint.HTTP.connect(upstream.scheme, upstream.host, upstream.port),
         path = request_path_with_query(conn),
         headers = filter_headers(conn.req_headers),
         {:ok, mint_conn, req_ref} <-
           Mint.HTTP.request(mint_conn, conn.method, path, headers, body),
         {:ok, mint_conn, resp} <-
           receive_response(mint_conn, req_ref, %{status: 502, headers: [], body: []}) do
      Mint.HTTP.close(mint_conn)
      send_upstream_response(conn, resp)
    else
      {:error, reason} ->
        Logger.error("Upstream forward failed for #{inspect(route.upstream)}: #{inspect(reason)}")
        send_resp(conn, 502, "Bad Gateway")
    end
  end

  defp read_full_body(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}

      {:more, chunk, conn} ->
        read_full_body(conn, [chunk | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_response(mint_conn, req_ref, acc) do
    receive do
      message ->
        case Mint.HTTP.stream(mint_conn, message) do
          :unknown ->
            receive_response(mint_conn, req_ref, acc)

          {:ok, mint_conn, responses} ->
            {done?, acc} = process_responses(responses, req_ref, acc)

            if done? do
              {:ok, mint_conn, %{acc | body: IO.iodata_to_binary(Enum.reverse(acc.body))}}
            else
              receive_response(mint_conn, req_ref, acc)
            end

          {:error, _mint_conn, reason, _responses} ->
            {:error, reason}
        end
    after
      15_000 ->
        {:error, :upstream_timeout}
    end
  end

  defp process_responses(responses, req_ref, acc) do
    Enum.reduce(responses, {false, acc}, fn
      {:status, ^req_ref, status}, {done, state} ->
        {done, %{state | status: status}}

      {:headers, ^req_ref, headers}, {done, state} ->
        {done, %{state | headers: state.headers ++ filter_headers(headers)}}

      {:data, ^req_ref, data}, {done, state} ->
        {done, %{state | body: [data | state.body]}}

      {:done, ^req_ref}, {_done, state} ->
        {true, state}

      _, pair ->
        pair
    end)
  end

  defp send_upstream_response(conn, %{status: status, headers: headers, body: body}) do
    conn =
      Enum.reduce(headers, conn, fn {k, v}, c ->
        put_resp_header(c, k, v)
      end)

    send_resp(conn, status, body)
  end

  defp request_path_with_query(%{request_path: path, query_string: ""}), do: path
  defp request_path_with_query(%{request_path: path, query_string: qs}), do: "#{path}?#{qs}"

  defp filter_headers(headers) do
    Enum.reject(headers, fn {k, _v} ->
      MapSet.member?(@hop_by_hop_headers, String.downcase(k))
    end)
  end
end
