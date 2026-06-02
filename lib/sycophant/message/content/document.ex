defmodule Sycophant.Message.Content.Document do
  @moduledoc """
  Document content part for multimodal messages (PDF, CSV, plain text, ...).

  Provide exactly one source: `:data` (base64-encoded bytes), `:url` (remote
  document), or `:file_id` (a provider-uploaded file reference obtained out of
  band). Set `:media_type` to the MIME type (e.g. `"application/pdf"`,
  `"text/csv"`). `:name` carries the title/filename. Set `:citations` to
  `true` to request document citations (Anthropic only; other wires ignore it).

  ## Examples

      # Base64-encoded PDF
      %Sycophant.Message.Content.Document{
        data: "JVBERi0xLjQK...",
        media_type: "application/pdf",
        name: "report.pdf"
      }

      # Remote PDF with citations requested
      %Sycophant.Message.Content.Document{
        url: "https://example.com/report.pdf",
        media_type: "application/pdf",
        citations: true
      }
  """
  use ZoiDefstruct

  defstruct __type__: Zoi.literal("Document") |> Zoi.default("Document"),
            type: Zoi.literal("document") |> Zoi.default("document"),
            data: Zoi.optional(Zoi.string()),
            url: Zoi.optional(Zoi.string()),
            file_id: Zoi.optional(Zoi.string()),
            media_type: Zoi.optional(Zoi.string()),
            name: Zoi.optional(Zoi.string()),
            citations: Zoi.default(Zoi.boolean(), false)
end

defimpl Inspect, for: Sycophant.Message.Content.Document do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(doc, opts) do
    fields =
      Enum.reject(
        [
          data: InspectHelpers.redact(doc.data),
          url: doc.url,
          file_id: doc.file_id,
          media_type: doc.media_type,
          name: doc.name,
          citations: doc.citations
        ],
        fn {k, v} -> is_nil(v) or (k == :citations and v == false) end
      )

    concat(["#Sycophant.Message.Content.Document<", to_doc(Map.new(fields), opts), ">"])
  end
end
