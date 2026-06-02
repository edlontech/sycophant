defmodule Sycophant.Recording.DocumentTest do
  @models Sycophant.RecordingCase.test_models(require: :document)
  use Sycophant.RecordingCase, async: true, parameterize: @models

  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.SampleDocument

  @tag recording_prefix: true
  test "answers a question about a PDF document", %{model: model} do
    document = %Content.Document{
      data: Base.encode64(SampleDocument.pdf()),
      media_type: "application/pdf",
      name: "sales-report"
    }

    messages = [
      Message.user([
        %Content.Text{
          text:
            "According to this PDF, which product is the best seller? " <>
              "Reply with only the product name."
        },
        document
      ])
    ]

    assert {:ok, response} = Sycophant.generate_text(model, messages, recording_opts([]))

    assert is_binary(response.text)
    assert String.downcase(response.text) =~ "gadget"
    assert response.usage.input_tokens > 0
  end
end

defmodule Sycophant.Recording.DocumentCitationsTest do
  use Sycophant.RecordingCase, async: true

  alias Sycophant.Citation
  alias Sycophant.Message
  alias Sycophant.Message.Content
  alias Sycophant.Response
  alias Sycophant.SampleDocument

  @model "anthropic:claude-haiku-4-5-20251001"

  @tag recording: "anthropic/claude-haiku-4-5-20251001/cites_a_pdf_document"
  test "decodes citations from an Anthropic PDF response" do
    document = %Content.Document{
      data: Base.encode64(SampleDocument.pdf()),
      media_type: "application/pdf",
      name: "sales-report",
      citations: true
    }

    messages = [
      Message.user([
        %Content.Text{
          text: "According to this PDF, which product is the best seller? Cite the document."
        },
        document
      ])
    ]

    assert {:ok, response} = Sycophant.generate_text(@model, messages, recording_opts([]))

    assert is_binary(response.text)
    assert [%Citation{} | _] = response.citations

    assistant = List.last(Response.messages(response))

    assert Enum.any?(assistant.content, fn
             %Content.Text{citations: [%Citation{} | _]} -> true
             _ -> false
           end)
  end
end
