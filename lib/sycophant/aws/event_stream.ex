defmodule Sycophant.AWS.EventStream do
  @moduledoc """
  Decoder for the AWS event stream binary framing protocol.

  Used by Bedrock's `/converse-stream` endpoint which returns
  responses as binary-framed events rather than SSE.

  ## Frame layout

      | prelude (12 B) | headers (variable) | payload (variable) | message CRC (4 B) |

  The prelude contains `total_length` (4 B), `headers_length` (4 B),
  and `prelude_crc` (4 B, CRC-32 of the first 8 bytes).

  The trailing message CRC covers everything before it.
  """

  @prelude_size 12
  @message_crc_size 4
  @type_string 7

  @spec decode(binary()) :: {:ok, [map()]} | {:error, term()}
  def decode(data), do: decode_all(data, [])

  @spec decode_frame(binary()) ::
          {:ok, map(), binary()} | {:incomplete, binary()} | {:error, term()}
  def decode_frame(data) when byte_size(data) < @prelude_size do
    {:incomplete, data}
  end

  def decode_frame(
        <<total_length::big-unsigned-32, headers_length::big-unsigned-32,
          prelude_crc::big-unsigned-32, _rest::binary>> = data
      ) do
    prelude_bin = <<total_length::big-unsigned-32, headers_length::big-unsigned-32>>
    expected_prelude_crc = :erlang.crc32(prelude_bin)

    cond do
      prelude_crc != expected_prelude_crc ->
        {:error, :invalid_prelude_crc}

      byte_size(data) < total_length ->
        {:incomplete, data}

      true ->
        <<frame::binary-size(total_length), rest::binary>> = data

        <<message_body::binary-size(total_length - @message_crc_size),
          message_crc::big-unsigned-32>> = frame

        expected_message_crc = :erlang.crc32(message_body)

        if message_crc != expected_message_crc do
          {:error, :invalid_message_crc}
        else
          <<_prelude::binary-size(@prelude_size), headers_bin::binary-size(headers_length),
            payload::binary>> = message_body

          {:ok, %{headers: decode_headers(headers_bin), payload: payload}, rest}
        end
    end
  end

  defp decode_all(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_all(data, acc) do
    case decode_frame(data) do
      {:ok, event, rest} -> decode_all(rest, [event | acc])
      {:incomplete, _} -> {:error, :incomplete_frame}
      {:error, _} = error -> error
    end
  end

  defp decode_headers(bin), do: decode_headers(bin, %{})

  defp decode_headers(<<>>, acc), do: acc

  defp decode_headers(
         <<name_len::8, name::binary-size(name_len), @type_string, value_len::big-unsigned-16,
           value::binary-size(value_len), rest::binary>>,
         acc
       ) do
    decode_headers(rest, Map.put(acc, name, value))
  end
end
