defmodule Sycophant.AWS.EventStreamTest do
  use ExUnit.Case, async: true

  alias Sycophant.AWS.EventStream

  describe "decode/1" do
    test "returns {:ok, []} for empty binary" do
      assert {:ok, []} = EventStream.decode(<<>>)
    end

    test "decodes a valid frame with headers and JSON payload" do
      payload = ~s({"type":"content","body":"hello"})
      headers = %{":event-type" => "ContentBlockDelta", ":content-type" => "application/json"}
      frame = build_frame(headers, payload)

      assert {:ok, [event]} = EventStream.decode(frame)
      assert event.headers == headers
      assert event.payload == payload
    end

    test "decodes multiple consecutive frames" do
      frame1 = build_frame(%{":event-type" => "Start"}, "first")
      frame2 = build_frame(%{":event-type" => "End"}, "second")

      assert {:ok, [e1, e2]} = EventStream.decode(frame1 <> frame2)
      assert e1.payload == "first"
      assert e1.headers[":event-type"] == "Start"
      assert e2.payload == "second"
      assert e2.headers[":event-type"] == "End"
    end
  end

  describe "decode_frame/1" do
    test "returns {:incomplete, data} for less than 12 bytes" do
      data = <<1, 2, 3, 4, 5>>
      assert {:incomplete, ^data} = EventStream.decode_frame(data)
    end

    test "returns {:incomplete, data} for truncated frame" do
      payload = "hello"
      headers = %{":event-type" => "Test"}
      frame = build_frame(headers, payload)
      truncated = binary_part(frame, 0, byte_size(frame) - 5)

      assert {:incomplete, ^truncated} = EventStream.decode_frame(truncated)
    end

    test "returns {:error, :invalid_prelude_crc} for bad prelude CRC" do
      payload = "hello"
      headers = %{":event-type" => "Test"}
      frame = build_frame(headers, payload)

      <<total_len::32, headers_len::32, _crc::32, rest::binary>> = frame
      bad_frame = <<total_len::32, headers_len::32, 0xDEADBEEF::32, rest::binary>>

      assert {:error, :invalid_prelude_crc} = EventStream.decode_frame(bad_frame)
    end

    test "returns {:error, :invalid_message_crc} for bad message CRC" do
      payload = "hello"
      headers = %{":event-type" => "Test"}
      frame = build_frame(headers, payload)

      corrupted = binary_part(frame, 0, byte_size(frame) - 4) <> <<0xDEADBEEF::32>>

      assert {:error, :invalid_message_crc} = EventStream.decode_frame(corrupted)
    end

    test "decodes frame with multiple headers" do
      headers = %{
        ":event-type" => "ContentBlockDelta",
        ":content-type" => "application/json",
        ":message-type" => "event"
      }

      frame = build_frame(headers, "payload")

      assert {:ok, event, <<>>} = EventStream.decode_frame(frame)
      assert event.headers == headers
      assert event.payload == "payload"
    end

    test "returns remaining bytes after successful decode" do
      frame = build_frame(%{"type" => "test"}, "data")
      trailing = <<1, 2, 3>>

      assert {:ok, event, ^trailing} = EventStream.decode_frame(frame <> trailing)
      assert event.payload == "data"
    end
  end

  defp build_frame(headers_map, payload) when is_binary(payload) do
    headers_bin = encode_headers(headers_map)
    headers_length = byte_size(headers_bin)
    total_length = 12 + headers_length + byte_size(payload) + 4

    prelude_bin =
      <<total_length::big-unsigned-integer-size(32),
        headers_length::big-unsigned-integer-size(32)>>

    prelude_crc = :erlang.crc32(prelude_bin)

    message_without_crc =
      <<prelude_bin::binary, prelude_crc::big-unsigned-integer-size(32), headers_bin::binary,
        payload::binary>>

    message_crc = :erlang.crc32(message_without_crc)

    <<message_without_crc::binary, message_crc::big-unsigned-integer-size(32)>>
  end

  defp encode_headers(headers_map) do
    headers_map
    |> Enum.sort()
    |> Enum.reduce(<<>>, fn {name, value}, acc ->
      name_bin = :erlang.iolist_to_binary(name)
      value_bin = :erlang.iolist_to_binary(value)

      acc <>
        <<byte_size(name_bin)::8, name_bin::binary, 7::8,
          byte_size(value_bin)::big-unsigned-integer-size(16), value_bin::binary>>
    end)
  end
end
