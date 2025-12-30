import pytest_lsp
from lsprotocol.types import ClientCapabilities, InitializeParams
from pytest_lsp import ClientServerConfig, LanguageClient


@pytest_lsp.fixture(
    config=ClientServerConfig(server_command=["/home/mike/crystalline/bin/crystalline"])
)
async def client(lsp_client: LanguageClient):
    params = InitializeParams(capabilities=ClientCapabilities())
    await lsp_client.initialize_session(params)
    yield
    await lsp_client.shutdown_session()
