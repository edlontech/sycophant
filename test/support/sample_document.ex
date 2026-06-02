defmodule Sycophant.SampleDocument do
  @moduledoc """
  Builds a small, valid PDF for document recording tests.

  The document is a single page of extractable text that states the best
  seller outright ("Best seller: Gadget"), so a model asked "which product is
  the best seller?" can answer "Gadget" by direct retrieval (no numeric
  comparison required). The bytes are deterministic, so the same request is
  produced on every record/replay run.
  """

  @text "Quarterly Sales Report. Best seller: Gadget. " <>
          "Revenue by product: Widget 2400, Gadget 2700, Gizmo 1350."

  @doc "Returns the raw bytes of a minimal single-page PDF containing `text/0`."
  @spec pdf() :: binary()
  def pdf do
    stream = "BT\n/F1 18 Tf\n72 720 Td\n(#{@text}) Tj\nET\n"

    objects = [
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " <>
        "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n",
      "4 0 obj\n<< /Length #{byte_size(stream)} >>\nstream\n#{stream}endstream\nendobj\n",
      "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"
    ]

    {body, offsets} =
      Enum.reduce(objects, {"%PDF-1.4\n", []}, fn obj, {acc, offsets} ->
        {acc <> obj, [byte_size(acc) | offsets]}
      end)

    xref_offset = byte_size(body)

    entries =
      offsets
      |> Enum.reverse()
      |> Enum.map_join("", fn offset ->
        String.pad_leading(Integer.to_string(offset), 10, "0") <> " 00000 n \n"
      end)

    xref = "xref\n0 6\n0000000000 65535 f \n" <> entries
    trailer = "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{xref_offset}\n%%EOF\n"

    body <> xref <> trailer
  end

  @doc "The plain-text content rendered inside `pdf/0`."
  @spec text() :: String.t()
  def text, do: @text
end
