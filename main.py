import asyncio

from lsprotocol import types
from pygls.lsp.client import LanguageClient


async def main():
    print("Hello from cr-analyzer!")
    client = LanguageClient("cr-analyzer", "v1")
    await client.start_io(
        "crystal",
        "run",
        "-Dpreview_mt",
        "-Dexecution_context",
        "src/bin/cra.cr",
    )

    # pygls start_io always pipes stderr; drain it for visibility.
    async def _drain_stderr(server_proc: asyncio.subprocess.Process | None):
        if server_proc is None or server_proc.stderr is None:
            return
        async for line in server_proc.stderr:
            print(f"[server stderr] {line.decode(errors='replace').rstrip()}")

    asyncio.create_task(_drain_stderr(client._server))
    response = await client.initialize_async(
        params=types.InitializeParams(
            capabilities=types.ClientCapabilities(
                workspace=types.WorkspaceClientCapabilities(apply_edit=True)
            ),
            root_uri="file:///home/mike/cr-analyzer",
        )
    )
    print(response)
    response = await client.text_document_completion_async(
        params=types.CompletionParams(
            text_document=types.TextDocumentIdentifier(
                uri="file:///home/mike/cr-analyzer/src/cra/types.cr"
            ),
            position=types.Position(line=0, character=0),
        )
    )

    print(f"Got {len(response.items)} completion items")

    response = await client.text_document_completion_async(
        params=types.CompletionParams(
            text_document=types.TextDocumentIdentifier(
                uri="file:///home/mike/cr-analyzer/src/cra/types.cr"
            ),
            position=types.Position(line=0, character=0),
        )
    )

    print(f"Got {len(response.items)} completion items")


if __name__ == "__main__":
    asyncio.run(main())
