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
  defstruct [:data, :url, :file_id, :media_type, :name, citations: false]

  @type t :: %__MODULE__{
          data: String.t() | nil,
          url: String.t() | nil,
          file_id: String.t() | nil,
          media_type: String.t() | nil,
          name: String.t() | nil,
          citations: boolean()
        }

  @doc "Deserializes a document content part from a plain map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      data: data["data"],
      url: data["url"],
      file_id: data["file_id"],
      media_type: data["media_type"],
      name: data["name"],
      citations: Map.get(data, "citations", false)
    }
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Message.Content.Document do
  import Sycophant.Serializable.Helpers

  def to_map(doc) do
    compact(%{
      "__type__" => "Document",
      "type" => "document",
      "data" => doc.data,
      "url" => doc.url,
      "file_id" => doc.file_id,
      "media_type" => doc.media_type,
      "name" => doc.name,
      "citations" => doc.citations
    })
  end
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
