import httpx


async def forward_request(method: str, url: str, headers: dict | None = None, body: bytes | None = None):
    async with httpx.AsyncClient(follow_redirects=False, timeout=20) as client:
        response = await client.request(method=method, url=url, headers=headers, content=body)
    return response
