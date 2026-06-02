defmodule Sycophant.Citation do
  @moduledoc """
  Provider-agnostic citation attached to assistant text.

  Unifies the location variants emitted by providers (currently Anthropic's
  five) behind a single shape. Citations are decoded from responses, attached
  to `Sycophant.Message.Content.Text` parts, and aggregated on
  `Sycophant.Response.citations`.
  """

  use ZoiDefstruct

  defstruct __type__: Zoi.literal("Citation") |> Zoi.default("Citation"),
            type:
              Zoi.enum(
                [
                  page_location: "page_location",
                  char_location: "char_location",
                  content_block_location: "content_block_location",
                  web_search_result_location: "web_search_result_location",
                  search_result_location: "search_result_location"
                ],
                coerce: true
              )
              |> Zoi.optional(),
            cited_text: Zoi.optional(Zoi.string()),
            document_index: Zoi.optional(Zoi.integer()),
            document_title: Zoi.optional(Zoi.string()),
            file_id: Zoi.optional(Zoi.string()),
            unit:
              Zoi.enum([page: "page", char: "char", block: "block"], coerce: true)
              |> Zoi.optional(),
            start_index: Zoi.optional(Zoi.integer()),
            end_index: Zoi.optional(Zoi.integer()),
            url: Zoi.optional(Zoi.string()),
            title: Zoi.optional(Zoi.string()),
            source: Zoi.optional(Zoi.string())
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
