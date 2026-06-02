defmodule Sycophant.Citation do
  @moduledoc """
  Provider-agnostic citation attached to assistant text.

  Unifies the location variants emitted by providers (currently Anthropic's
  five) behind a single shape. Citations are decoded from responses, attached
  to `Sycophant.Message.Content.Text` parts, and aggregated on
  `Sycophant.Response.citations`.
  """

  defstruct [
    :type,
    :cited_text,
    :document_index,
    :document_title,
    :file_id,
    :unit,
    :start_index,
    :end_index,
    :url,
    :title,
    :source
  ]

  @type location_type ::
          :page_location
          | :char_location
          | :content_block_location
          | :web_search_result_location
          | :search_result_location

  @type t :: %__MODULE__{
          type: location_type() | nil,
          cited_text: String.t() | nil,
          document_index: integer() | nil,
          document_title: String.t() | nil,
          file_id: String.t() | nil,
          unit: :page | :char | :block | nil,
          start_index: integer() | nil,
          end_index: integer() | nil,
          url: String.t() | nil,
          title: String.t() | nil,
          source: String.t() | nil
        }

  @location_types %{
    "page_location" => :page_location,
    "char_location" => :char_location,
    "content_block_location" => :content_block_location,
    "web_search_result_location" => :web_search_result_location,
    "search_result_location" => :search_result_location
  }

  @units %{"page" => :page, "char" => :char, "block" => :block}

  @doc "Deserializes a citation from a plain map."
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      type: Map.get(@location_types, data["type"]),
      cited_text: data["cited_text"],
      document_index: data["document_index"],
      document_title: data["document_title"],
      file_id: data["file_id"],
      unit: Map.get(@units, data["unit"]),
      start_index: data["start_index"],
      end_index: data["end_index"],
      url: data["url"],
      title: data["title"],
      source: data["source"]
    }
  end
end

defimpl Sycophant.Serializable, for: Sycophant.Citation do
  import Sycophant.Serializable.Helpers

  def to_map(citation) do
    compact(%{
      "__type__" => "Citation",
      "type" => atom_to_string(citation.type),
      "cited_text" => citation.cited_text,
      "document_index" => citation.document_index,
      "document_title" => citation.document_title,
      "file_id" => citation.file_id,
      "unit" => atom_to_string(citation.unit),
      "start_index" => citation.start_index,
      "end_index" => citation.end_index,
      "url" => citation.url,
      "title" => citation.title,
      "source" => citation.source
    })
  end

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom), do: Atom.to_string(atom)
end

defimpl Inspect, for: Sycophant.Citation do
  import Inspect.Algebra
  alias Sycophant.InspectHelpers

  def inspect(citation, opts) do
    fields =
      Enum.reject(
        [
          type: citation.type,
          cited_text: InspectHelpers.truncate(citation.cited_text),
          document_index: citation.document_index,
          start_index: citation.start_index,
          end_index: citation.end_index
        ],
        fn {_, v} -> is_nil(v) end
      )

    concat(["#Sycophant.Citation<", to_doc(Map.new(fields), opts), ">"])
  end
end
