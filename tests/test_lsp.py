import pytest
from lsprotocol.types import (
    ClientCapabilities,
    InitializeParams,
    TextDocumentCompletionParams,
)
from pytest_lsp import ClientServerConfig, LanguageClient


@pytest.mark.asyncio
async def test_init(client: LanguageClient):
    results = await client.text_document_completion_async(
        params=TextDocumentCompletionParams()
    )
