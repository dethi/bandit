defmodule Bandit.HTTP1.Socket do
  @moduledoc false
  # This module implements the lower level parts of HTTP/1 (roughly, the aspects of the protocol
  # described in RFC 9112 as opposed to RFC 9110). It is similar in spirit to
  # `Bandit.HTTP2.Stream` for HTTP/2, and indeed both implement the `Bandit.HTTPTransport`
  # behaviour. An instance of this struct is maintained as the state of a `Bandit.HTTP1.Handler`
  # process, and it moves an HTTP/1 request through its lifecycle by calling functions defined on
  # this module. This state is also tracked within the `Bandit.HTTP1.Adapter` instance that backs
  # Bandit's Plug API.

  @behaviour Bandit.HTTPTransport

  defstruct socket: nil,
            buffer: <<>>,
            read_state: :unread,
            write_state: :unsent,
            bytes_remaining: nil,
            body_encoding: nil,
            version: :"HTTP/1.0",
            keepalive: false,
            transport_info: nil,
            opts: []

  @typedoc "An HTTP/1 read state"
  @type read_state :: :unread | :headers_read | :read

  @typedoc "An HTTP/1 write state"
  @type write_state :: :unsent | :writing | :chunking | :sent

  @typedoc "The information necessary to communicate to/from a socket"
  @type t :: %__MODULE__{
          socket: ThousandIsland.Socket.t(),
          buffer: iodata(),
          read_state: read_state(),
          write_state: write_state(),
          bytes_remaining: non_neg_integer() | :chunked | nil,
          body_encoding: nil | binary(),
          version: nil | :"HTTP/1.1" | :"HTTP/1.0",
          keepalive: boolean(),
          transport_info: Bandit.TransportInfo.t(),
          opts: %{
            required(:http_1) => Bandit.http_1_options()
          }
        }

  @impl Bandit.HTTPTransport
  def version(%__MODULE__{} = socket), do: socket.version

  @impl Bandit.HTTPTransport
  def read_headers(%__MODULE__{read_state: :unread} = socket) do
    {method, request_target, socket} = do_read_request_line!(socket)
    {headers, socket} = do_read_headers!(socket)
    body_size = get_content_length!(headers)
    body_encoding = Bandit.Headers.get_header(headers, "transfer-encoding")
    connection = Bandit.Headers.get_header(headers, "connection")
    keepalive = should_keepalive?(socket.version, connection)
    socket = %{socket | keepalive: keepalive}

    case {body_size, body_encoding} do
      {nil, nil} ->
        # No body, so just go straight to 'read'
        {:ok, method, request_target, headers, %{socket | read_state: :read}}

      {body_size, nil} ->
        bytes_remaining = body_size - byte_size(socket.buffer)
        socket = %{socket | read_state: :headers_read, bytes_remaining: bytes_remaining}
        {:ok, method, request_target, headers, socket}

      {nil, body_encoding} ->
        socket = %{socket | read_state: :headers_read, body_encoding: body_encoding}
        {:ok, method, request_target, headers, socket}

      {_content_length, _body_encoding} ->
        request_error!(
          "Request cannot contain both 'content-length' and 'transfer-encoding' (RFC9112§6.3.3)"
        )
    end
  end

  defp do_read_request_line!(socket, request_target \\ nil) do
    packet_size = Keyword.get(socket.opts.http_1, :max_request_line_length, 10_000)

    case :erlang.decode_packet(:http_bin, socket.buffer, packet_size: packet_size) do
      {:more, _len} ->
        chunk = read_available_for_header!(socket.socket)
        do_read_request_line!(%{socket | buffer: socket.buffer <> chunk}, request_target)

      {:ok, {:http_request, method, request_target, version}, rest} ->
        version = get_version!(version)
        request_target = resolve_request_target!(request_target)
        method = to_string(method)
        socket = %{socket | buffer: rest, version: version}
        {method, request_target, socket}

      {:ok, {:http_error, reason}, _rest} ->
        request_error!("Request line HTTP error: #{inspect(reason)}")

      {:error, :invalid} ->
        request_error!("Request uri is too long", :request_uri_too_long)

      {:error, reason} ->
        request_error!("Request line unknown error: #{inspect(reason)}")
    end
  end

  defp get_version!({1, 1}), do: :"HTTP/1.1"
  defp get_version!({1, 0}), do: :"HTTP/1.0"
  defp get_version!(other), do: request_error!("Invalid HTTP version: #{inspect(other)}")

  # Unwrap different request_targets returned by :erlang.decode_packet/3
  defp resolve_request_target!({:abs_path, path}), do: {nil, nil, nil, path}

  defp resolve_request_target!({:absoluteURI, scheme, host, :undefined, path}),
    do: {to_string(scheme), host, nil, path}

  defp resolve_request_target!({:absoluteURI, scheme, host, port, path}),
    do: {to_string(scheme), host, port, path}

  defp resolve_request_target!(:*), do: {nil, nil, nil, :*}

  defp resolve_request_target!({:scheme, _scheme, _path}),
    do: request_error!("schemeURI is not supported")

  defp resolve_request_target!(_request_target),
    do: request_error!("Unsupported request target (RFC9112§3.2)")

  defp do_read_headers!(socket, headers \\ []) do
    packet_size = Keyword.get(socket.opts.http_1, :max_header_length, 10_000)

    case :erlang.decode_packet(:httph_bin, socket.buffer, packet_size: packet_size) do
      {:more, _len} ->
        chunk = read_available_for_header!(socket.socket)
        socket = %{socket | buffer: socket.buffer <> chunk}
        do_read_headers!(socket, headers)

      {:ok, {:http_header, _, header, _, value}, rest} ->
        socket = %{socket | buffer: rest}
        headers = [{header |> to_string() |> String.downcase(:ascii), value} | headers]

        if length(headers) <= Keyword.get(socket.opts.http_1, :max_header_count, 50) do
          do_read_headers!(socket, headers)
        else
          request_error!("Too many headers", :request_header_fields_too_large)
        end

      {:ok, :http_eoh, rest} ->
        socket = %{socket | read_state: :headers_read, buffer: rest}
        {headers, socket}

      {:ok, {:http_error, reason}, _rest} ->
        request_error!("Header read HTTP error: #{inspect(reason)}")

      {:error, :invalid} ->
        request_error!("Header too long", :request_header_fields_too_large)

      {:error, reason} ->
        request_error!("Header read unknown error: #{inspect(reason)}")
    end
  end

  defp get_content_length!(headers) do
    case Bandit.Headers.get_content_length(headers) do
      {:ok, content_length} -> content_length
      {:error, reason} -> request_error!("Content length unknown error: #{inspect(reason)}")
    end
  end

  # `close` & `keep-alive` always means what they say, otherwise keepalive if we're on HTTP/1.1
  # Case insensitivity per RFC9110§7.6.1
  defp should_keepalive?(_, "close"), do: false
  defp should_keepalive?(_, "keep-alive"), do: true
  defp should_keepalive?(_, "Keep-Alive"), do: true
  defp should_keepalive?(:"HTTP/1.1", _), do: true
  defp should_keepalive?(_, _), do: false

  @impl Bandit.HTTPTransport
  def read_data(
        %__MODULE__{read_state: :headers_read, bytes_remaining: bytes_remaining} = socket,
        opts
      )
      when is_number(bytes_remaining) do
    {to_return, buffer, bytes_remaining} =
      do_read_content_length_data!(socket.socket, socket.buffer, bytes_remaining, opts)

    if byte_size(buffer) == 0 && bytes_remaining == 0 do
      {:ok, to_return, %{socket | read_state: :read, buffer: <<>>, bytes_remaining: 0}}
    else
      {:more, to_return, %{socket | buffer: buffer, bytes_remaining: bytes_remaining}}
    end
  end

  def read_data(%__MODULE__{read_state: :headers_read, body_encoding: "chunked"} = socket, opts) do
    read_size = Keyword.get(opts, :read_length, 1_000_000)
    read_timeout = Keyword.get(opts, :read_timeout)

    {body, buffer} =
      do_read_chunked_data!(socket.socket, socket.buffer, <<>>, read_size, read_timeout)

    body = IO.iodata_to_binary(body)

    {:ok, body, %{socket | read_state: :read, buffer: buffer}}
  end

  def read_data(%__MODULE__{read_state: :headers_read, body_encoding: body_encoding}, _opts)
      when not is_nil(body_encoding) do
    request_error!("Unsupported transfer-encoding")
  end

  def read_data(%__MODULE__{} = socket, _opts), do: {:ok, <<>>, socket}

  defp do_read_content_length_data!(socket, buffer, bytes_remaining, opts) do
    max_desired_bytes = Keyword.get(opts, :length, 8_000_000)

    cond do
      bytes_remaining < 0 ->
        # We have read more bytes than content-length suggested should have been sent. This is
        # veering into request smuggling territory and should never happen with a well behaved
        # client. The safest thing to do is just error
        request_error!("Excess body read")

      byte_size(buffer) >= max_desired_bytes || bytes_remaining == 0 ->
        # We can satisfy the read request entirely from our buffer
        bytes_to_return = min(max_desired_bytes, byte_size(buffer))
        <<to_return::binary-size(bytes_to_return), rest::binary>> = buffer
        {to_return, rest, bytes_remaining}

      true ->
        # We need to read off the wire
        bytes_to_read = min(max_desired_bytes - byte_size(buffer), bytes_remaining)
        read_size = Keyword.get(opts, :read_length, 1_000_000)
        read_timeout = Keyword.get(opts, :read_timeout)

        iolist = read!(socket, bytes_to_read, [], read_size, read_timeout)
        to_return = IO.iodata_to_binary([buffer | iolist])
        bytes_remaining = bytes_remaining - (byte_size(to_return) - byte_size(buffer))
        {to_return, <<>>, bytes_remaining}
    end
  end

  defp do_read_chunked_data!(socket, buffer, body, read_size, read_timeout) do
    case :binary.split(buffer, "\r\n") do
      ["0", _] ->
        {IO.iodata_to_binary(body), buffer}

      [chunk_size, rest] ->
        chunk_size = String.to_integer(chunk_size, 16)

        case rest do
          <<next_chunk::binary-size(chunk_size), ?\r, ?\n, rest::binary>> ->
            do_read_chunked_data!(socket, rest, [body, next_chunk], read_size, read_timeout)

          _ ->
            to_read = chunk_size - byte_size(rest)

            if to_read > 0 do
              iolist = read!(socket, to_read, [], read_size, read_timeout)
              buffer = IO.iodata_to_binary([buffer | iolist])
              do_read_chunked_data!(socket, buffer, body, read_size, read_timeout)
            else
              chunk = read_available!(socket, read_timeout)
              buffer = buffer <> chunk
              do_read_chunked_data!(socket, buffer, body, read_size, read_timeout)
            end
        end

      _ ->
        chunk = read_available!(socket, read_timeout)
        buffer = buffer <> chunk
        do_read_chunked_data!(socket, buffer, body, read_size, read_timeout)
    end
  end

  ##################
  # Internal Reading
  ##################

  @compile {:inline, read_available_for_header!: 1}
  @spec read_available_for_header!(ThousandIsland.Socket.t()) :: binary()
  defp read_available_for_header!(socket) do
    case ThousandIsland.Socket.recv(socket, 0) do
      {:ok, chunk} -> chunk
      {:error, :timeout} -> request_error!("Header read timeout", :request_timeout)
      {:error, reason} -> request_error!("Header read socket error: #{inspect(reason)}")
    end
  end

  @compile {:inline, read_available!: 2}
  @spec read_available!(ThousandIsland.Socket.t(), timeout()) :: binary()
  defp read_available!(socket, read_timeout) do
    case ThousandIsland.Socket.recv(socket, 0, read_timeout) do
      {:ok, chunk} -> chunk
      {:error, :timeout} -> <<>>
      {:error, reason} -> request_error!(reason)
    end
  end

  @dialyzer {:no_improper_lists, read!: 5}
  @spec read!(
          ThousandIsland.Socket.t(),
          non_neg_integer(),
          iolist(),
          non_neg_integer(),
          timeout()
        ) ::
          iolist()
  defp read!(socket, to_read, already_read, read_size, read_timeout) do
    case ThousandIsland.Socket.recv(socket, min(to_read, read_size), read_timeout) do
      {:ok, chunk} ->
        remaining_bytes = to_read - byte_size(chunk)

        if remaining_bytes > 0 do
          read!(socket, remaining_bytes, [already_read | chunk], read_size, read_timeout)
        else
          [already_read | chunk]
        end

      {:error, :timeout} ->
        already_read

      {:error, reason} ->
        request_error!(reason)
    end
  end

  @impl Bandit.HTTPTransport
  def send_headers(%__MODULE__{write_state: :unsent} = socket, status, headers, body_disposition) do
    resp_line = "#{socket.version} #{status} #{Plug.Conn.Status.reason_phrase(status)}\r\n"

    {headers, write_state} =
      case body_disposition do
        :raw -> {headers, :writing}
        :chunk_encoded -> {[{"transfer-encoding", "chunked"} | headers], :chunking}
        :no_body -> {headers, :sent}
        :inform -> {headers, :unsent}
      end

    headers =
      headers
      |> Enum.map(fn {k, v} -> [k, ": ", v, "\r\n"] end)
      |> then(&[&1 | ["\r\n"]])

    _ = ThousandIsland.Socket.send(socket.socket, [resp_line | headers])

    %{socket | write_state: write_state}
  end

  @impl Bandit.HTTPTransport
  def send_data(%__MODULE__{write_state: :writing} = socket, data, end_request) do
    _ = ThousandIsland.Socket.send(socket.socket, data)
    write_state = if end_request, do: :sent, else: :writing
    %{socket | write_state: write_state}
  end

  def send_data(%__MODULE__{write_state: :chunking} = socket, data, end_request) do
    byte_size = data |> IO.iodata_length()
    payload = [Integer.to_string(byte_size, 16), "\r\n", data, "\r\n"]
    _ = ThousandIsland.Socket.send(socket.socket, payload)
    write_state = if end_request, do: :sent, else: :chunking
    %{socket | write_state: write_state}
  end

  @impl Bandit.HTTPTransport
  def sendfile(%__MODULE__{write_state: :writing} = socket, path, offset, length) do
    _ = ThousandIsland.Socket.sendfile(socket.socket, path, offset, length)
    socket
  end

  @impl Bandit.HTTPTransport
  def ensure_completed(%__MODULE__{read_state: :read} = socket), do: socket

  def ensure_completed(%__MODULE__{} = socket) do
    case read_data(socket, []) do
      {:ok, _data, socket} -> socket
      {:more, _data, socket} -> ensure_completed(socket)
    end
  end

  def send_error(%__MODULE__{} = socket, status) do
    _ =
      ThousandIsland.Socket.send(
        socket.socket,
        "#{socket.version} #{status} #{Plug.Conn.Status.reason_phrase(status)}\r\n\r\n"
      )

    ThousandIsland.Socket.close(socket.socket)
  end

  @spec request_error!(term()) :: no_return()
  @spec request_error!(term(), atom()) :: no_return()
  defp request_error!(reason, status \\ :bad_request) do
    raise Bandit.HTTP1.Error, message: reason, status: Plug.Conn.Status.code(status)
  end
end
