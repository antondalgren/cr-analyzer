import asyncio

from lsprotocol import types
from pygls.lsp.client import LanguageClient


async def main():
    print("Hello from cr-analyzer!")
    client = LanguageClient("cr-analyzer", "v1")
    await client.start_tcp("127.0.0.1", 9998)
    await client.initialize_async(
        params=types.InitializeParams(
            capabilities=types.ClientCapabilities(
                workspace=types.WorkspaceClientCapabilities(apply_edit=True)
            ),
            root_uri="file:///home/mike/cr-analyzer",
        )
    )


if __name__ == "__main__":
    asyncio.run(main())
